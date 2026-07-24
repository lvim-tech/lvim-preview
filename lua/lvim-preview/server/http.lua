-- lvim-preview.server.http: HTTP/1.1 request parsing, routing and file serving. Everything
-- here runs inside a libuv read callback (a "fast" context) where vim.api / vim.fn are
-- forbidden, so it touches only: pure string work, `vim.fs.normalize` / `vim.uri_decode`
-- (pure), async `uv.fs_*` reads, and the plain-string content CACHE the main thread fills.
-- No vim.schedule is needed on the serve path — nothing here reads editor state live.
--
-- Routing:
--   * /@lvim-preview/…  → the plugin's own static/ dir (the shell's client.js/css + vendored
--     assets). Confined to static/ by the same segment guard as the root.
--   * /@lvim-artifact/<slug>/…  → a registered build ARTIFACT (see lvim-preview.artifact): its
--     viewer page at the bare prefix, and its own directory — NOT state.root — as the confined
--     serve root for the produced file and its siblings.
--   * anything else      → resolved UNDER the servable root with a strict segment-stack guard
--     (no `..` escape, no dotfiles unless serve_hidden). The previewed file (and any other
--     previewable file under the root) is wrapped in the shell; html is served with the WS
--     client injected; every other file is streamed with its MIME type. No directory listings.
--
---@module "lvim-preview.server.http"

local uv = vim.uv
local mime = require("lvim-preview.server.mime")
local template = require("lvim-preview.template")
local util = require("lvim-preview.util")
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")

local M = {}

-- The plugin's static/ directory, resolved ONCE at load (main thread) from this file's path —
-- nvim_get_runtime_file is a vim.api call and must not run in the fast serve callback.
local STATIC_DIR = (function()
    local this = debug.getinfo(1, "S").source:sub(2)
    return (vim.fs.normalize(this):gsub("/lua/lvim%-preview/server/http%.lua$", "/static"))
end)()

M.STATIC_DIR = STATIC_DIR

-- The URL prefix under which the plugin's own static assets are served.
local STATIC_PREFIX = "/@lvim-preview/"

--- Whether the request head is a WebSocket upgrade.
---@param request string
---@return boolean
function M.is_upgrade(request)
    return request:match("[Uu]pgrade:%s*websocket") ~= nil
end

--- The decoded request path (GET only), query stripped, or nil for a non-GET / malformed line.
---@param request string
---@return string? path
function M.request_path(request)
    local raw = request:match("^GET%s+([^%s]+)%s+HTTP/1%.[01]")
    if not raw then
        return nil
    end
    raw = raw:gsub("%?.*$", "")
    return vim.uri_decode(raw)
end

--- Join a URL path under `root` with a strict guard: resolve `.`/`..` on a segment stack that
--- can never pop above the root, and reject dotfiles unless `allow_hidden`. Returns the absolute
--- filesystem path, or nil when the path escapes the root or hits a rejected dotfile.
---@param root string
---@param urlpath string
---@param allow_hidden boolean
---@return string? abspath
local function safe_join(root, urlpath, allow_hidden)
    local stack = {}
    for seg in urlpath:gmatch("[^/]+") do
        if seg == "." then -- skip
        elseif seg == ".." then
            if #stack == 0 then
                return nil -- escape attempt
            end
            stack[#stack] = nil
        else
            if not allow_hidden and seg:sub(1, 1) == "." then
                return nil -- a dotfile (.env / .git / …) — do not leak
            end
            stack[#stack + 1] = seg
        end
    end
    local rel = table.concat(stack, "/")
    return vim.fs.normalize(root) .. (rel ~= "" and ("/" .. rel) or "")
end

--- Send a complete HTTP response and close the connection (Connection: close — one request per
--- socket; the browser opens parallel sockets for assets, which is fine).
---@param client uv.uv_tcp_t
---@param status string        e.g. "200 OK"
---@param content_type string
---@param body string
local function respond(client, status, content_type, body)
    local head = "HTTP/1.1 "
        .. status
        .. "\r\n"
        .. "Content-Type: "
        .. content_type
        .. "\r\n"
        .. "Content-Length: "
        .. #body
        .. "\r\n"
        .. "Cache-Control: no-store\r\n"
        .. "Connection: close\r\n\r\n"
    client:write(head .. body, function()
        pcall(function()
            client:close()
        end)
    end)
end

--- 404 helper.
---@param client uv.uv_tcp_t
local function not_found(client)
    respond(client, "404 Not Found", "text/plain; charset=utf-8", "404 Not Found")
end

--- Send a 301 to `location` and close. Used so an artifact page requested without its trailing
--- slash still resolves its relative asset URLs against the artifact, not against the prefix.
---@param client uv.uv_tcp_t
---@param location string
local function redirect(client, location)
    local body = "301 Moved Permanently"
    local head = "HTTP/1.1 301 Moved Permanently\r\n"
        .. "Location: "
        .. location
        .. "\r\n"
        .. "Content-Type: text/plain; charset=utf-8\r\n"
        .. "Content-Length: "
        .. #body
        .. "\r\n"
        .. "Cache-Control: no-store\r\n"
        .. "Connection: close\r\n\r\n"
    client:write(head .. body, function()
        pcall(function()
            client:close()
        end)
    end)
end

--- Send a bare status line as the whole response and close. Used by the connection loop for
--- protocol-level refusals it decides BEFORE a request is parseable (an over-long header
--- block), so that path does not have to hand-roll a response.
---@param client uv.uv_tcp_t
---@param status string  e.g. "431 Request Header Fields Too Large"
---@return nil
function M.refuse(client, status)
    respond(client, status, "text/plain; charset=utf-8", status)
end

--- Read a file fully off disk asynchronously, then call `done(data|nil)`. Confined to uv.fs_*
--- (callback-safe); never touches editor state.
---@param path string
---@param done fun(data: string?)
local function read_file(path, done)
    uv.fs_open(path, "r", 420, function(oerr, fd)
        if oerr or not fd then
            return done(nil)
        end
        uv.fs_fstat(fd, function(serr, stat)
            if serr or not stat then
                uv.fs_close(fd, function() end)
                return done(nil)
            end
            uv.fs_read(fd, stat.size, 0, function(rerr, data)
                uv.fs_close(fd, function() end)
                if rerr then
                    return done(nil)
                end
                done(data)
            end)
        end)
    end)
end

--- Serve a plugin static asset (client.js / style.css / vendored dist).
---@param client uv.uv_tcp_t
---@param urlpath string  the part AFTER the STATIC_PREFIX
local function serve_static(client, urlpath)
    local path = safe_join(STATIC_DIR, urlpath, false)
    if not path then
        return not_found(client)
    end
    read_file(path, function(data)
        if not data then
            return not_found(client)
        end
        respond(client, "200 OK", mime.for_path(path), data)
    end)
end

--- Serve a registered artifact: its viewer page at the bare `<slug>/`, or any file from the
--- produced file's own directory below that.
---
--- The confined root here is the ARTIFACT's directory, never `state.root`: build output lives
--- outside any project root the documents are served from. The same segment-stack guard applies,
--- so nothing above that directory is reachable.
---@param client uv.uv_tcp_t
---@param rest string  the part AFTER config.artifact.prefix ("<slug>" | "<slug>/" | "<slug>/<rel>")
local function serve_artifact(client, rest)
    local slug = rest:match("^([^/]+)")
    if not slug then
        return not_found(client)
    end
    local art = state.artifact_slugs[slug]
    if not art then
        return not_found(client)
    end
    local rel = rest:sub(#slug + 1)
    if rel == "" then
        -- No trailing slash: the page's relative URLs would resolve one level too high.
        return redirect(client, art.url_path)
    end
    if rel == "/" then
        if art.viewer == "raw" then
            -- No wrapper at all: the bytes as they are, with their MIME type. A `raw` artifact is
            -- addressable and re-fetchable, but nothing on the page listens for reload frames.
            return read_file(art.path, function(data)
                if not data then
                    return not_found(client)
                end
                respond(client, "200 OK", mime.for_path(art.path), data)
            end)
        end
        if art.viewer == "html" then
            -- The produced page as authored, with our client injected so an `artifact` frame can
            -- refresh it and a `status` frame can raise an overlay over it.
            return read_file(art.path, function(data)
                if not data then
                    return respond(client, "200 OK", "text/html; charset=utf-8", template.artifact_pending(art))
                end
                respond(client, "200 OK", "text/html; charset=utf-8", template.inject_reload(data, art))
            end)
        end
        return respond(client, "200 OK", "text/html; charset=utf-8", template.pdf_shell(art))
    end

    local path = safe_join(art.dir, rel, config.serve_hidden)
    if not path then
        return not_found(client)
    end
    read_file(path, function(data)
        if not data then
            return not_found(client)
        end
        respond(client, "200 OK", mime.for_path(path), data)
    end)
end

--- Serve a document that lives under the root (or the previewed buffer's cached content).
---@param client uv.uv_tcp_t
---@param urlpath string
local function serve_doc(client, urlpath)
    -- "/" maps to a previewed file so a tab opened at the root shows a document. With several
    -- previewed at once the first by url_path wins — every other tab is opened at its own URL.
    if urlpath == "" or urlpath == "/" then
        local first = state.list()[1]
        urlpath = first and first.url_path or "/"
    end
    -- Resolve the document by the REQUESTED url_path, not by "the" previewed file: any number of
    -- documents are live at once, and each tab asks for its own. Matching on the stored url_path
    -- also keeps this fast-path safe (no vim.fs call inside the libuv callback).
    local doc = state.doc_for_url(urlpath)

    -- `serve_hidden` is the SINGLE switch for dotfiles: it governs what the server will serve AND
    -- what the picker offers, so the two can never disagree (a file you can pick is a file you can
    -- open). `..` escapes stay blocked either way.
    local path = safe_join(state.root, urlpath, config.serve_hidden)
    if not path then
        return not_found(client)
    end

    local kind = util.kind_for(path)

    -- A previewed markdown/org buffer: wrap its CACHED (possibly unsaved) content in the
    -- shell so first paint already reflects the editor; WS `update` frames then keep it live.
    if doc and kind and doc.content ~= nil then
        return respond(client, "200 OK", "text/html; charset=utf-8", template.shell(kind, doc.content, urlpath))
    end

    read_file(path, function(data)
        if not data then
            return not_found(client)
        end
        if kind then
            -- Another previewable file under the root (e.g. a linked .md): wrap its disk content.
            return respond(client, "200 OK", "text/html; charset=utf-8", template.shell(kind, data, urlpath))
        end
        respond(client, "200 OK", mime.for_path(path), data)
    end)
end

--- Route + serve a parsed GET request. Called once per HTTP connection from the server loop.
---@param client uv.uv_tcp_t
---@param request string  the full request head
function M.serve(client, request)
    local path = M.request_path(request)
    if not path then
        return respond(client, "400 Bad Request", "text/plain; charset=utf-8", "400 Bad Request")
    end
    if path:sub(1, #STATIC_PREFIX) == STATIC_PREFIX then
        return serve_static(client, path:sub(#STATIC_PREFIX))
    end
    local ap = config.artifact.prefix
    if #ap > 0 and path:sub(1, #ap) == ap then
        return serve_artifact(client, path:sub(#ap + 1))
    end
    serve_doc(client, path)
end

return M
