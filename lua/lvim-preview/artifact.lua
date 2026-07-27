-- lvim-preview.artifact: the PRODUCER seam — "here is a file another plugin produced; serve it
-- and refresh the browser when I say it changed".
--
-- This is a different source of truth from a previewed DOCUMENT and is deliberately general, not
-- a special case for any one producer. A document is a BUFFER whose text this plugin renders in
-- the browser (watch.lua pushes its content, client.js renders it). An artifact has no buffer and
-- no client-side render: it is a FILE on disk that some external toolchain writes — a compiled
-- PDF, a generated HTML page, an exported image — and the only thing the preview can know about
-- it is WHEN it became valid. Only the producer knows that: a build writes for seconds and a
-- half-written file must never be fetched, so the DEFAULT is an explicit `reload()` call, with a
-- filesystem watcher available (`watch = true`) for producers that have no completion signal.
--
-- URL namespace: artifacts live under the reserved `config.artifact.prefix`, exactly like the
-- plugin's own `/@lvim-preview/` static prefix. That sidesteps `state.root` entirely — build
-- output lives in `build/` directories anywhere on disk, and the "file is outside the servable
-- root" refusal that governs documents must not apply here. Each artifact confines its own
-- serving to the DIRECTORY of its file, resolved by the same segment-stack guard as the root, so
-- a produced HTML page can still load its sibling assets and nothing above it is reachable.
--
-- The producer's `id` is free-form (an absolute path, a project key) and is the registry key;
-- the URL identity is a short opaque `slug` assigned here, because an id may contain slashes,
-- spaces or anything else a URL path cannot carry. Re-registering the same id reuses its slug,
-- so a producer that re-registers after a restart keeps every already-open tab valid.
--
-- Inbound messages (a click in the viewer reaching the editor, i.e. inverse search) are OFF by
-- default and doubly gated: `config.artifact.allow_client_messages` must be on AND the artifact's
-- own spec must supply `on_message`. For every ordinary preview the browser stays the passive
-- viewer the rest of this plugin promises.
--
---@module "lvim-preview.artifact"

local uv = vim.uv
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local server = require("lvim-preview.server")
local util = require("lvim-preview.util")

local M = {}

--- What a producer hands to `require("lvim-preview").register_artifact(spec)`.
---@class LvimPreviewArtifactSpec
---@field id     string   Stable producer-chosen identity, e.g. "tex:/abs/path/main.tex". Free-form:
---                        re-registering the same id updates that artifact in place and keeps its URL.
---@field path   string   Absolute path of the produced file. It need not exist yet.
---@field viewer ("pdf"|"html"|"raw")?  How the browser presents it. Default: inferred from the
---                        extension (.pdf → "pdf", .html/.htm → "html", anything else → "raw").
---@field title  string?   Page title. Default: the file's basename.
---@field watch  boolean?  false (default) — the producer calls `reload()`, which is the only way
---                        to know a build finished coherently. true — a uv fs_event on the file's
---                        directory reloads on write, debounced by config.artifact.watch_debounce.
---@field on_message fun(msg: table)? Opt-in handler for INBOUND viewer messages (inverse search).
---   The message is UNTRUSTED: it arrives from a browser page, and with the server LAN-bound from
---   any client that knows the url path. The framework enforces `accepts` before calling this, so a
---   handler sees only the shapes its artifact declared.
---@field accepts string[]|fun(msg: table): boolean|nil  which inbound messages this artifact takes:
---   a list of `type` names, a validator, or nil for the built-in contract (a pdf artifact accepts
---   `synctex_edit` / `synctex_scroll` with finite page/x/y; anything else accepts everything).
---                        Also requires config.artifact.allow_client_messages = true.

-- Viewer inferred from the produced file's extension when the spec does not name one.
---@type table<string, string>
local EXT_VIEWER = {
    pdf = "pdf",
    html = "html",
    htm = "html",
}

---@type table<string, boolean>
local VIEWERS = { pdf = true, html = true, raw = true }

--- Notify helper, gated by config.notify (main thread only).
---@param msg string
---@param level integer?
local function notify(msg, level)
    if config.notify then
        vim.notify("lvim-preview: " .. msg, level or vim.log.levels.INFO)
    end
end

--- The address the LOCAL browser should hit (0.0.0.0 / :: → loopback for the opener).
---@return string
local function display_host()
    if state.host == "0.0.0.0" or state.host == "::" then
        return "127.0.0.1"
    end
    return state.host
end

--- Release an artifact's filesystem watcher and its debounce timer.
---@param art LvimPreviewArtifact
---@return nil
local function release_watch(art)
    if art.fs_event then
        pcall(function()
            art.fs_event:stop()
        end)
        if not art.fs_event:is_closing() then
            art.fs_event:close()
        end
        art.fs_event = nil
    end
    if art.timer then
        if not art.timer:is_closing() then
            art.timer:stop()
            art.timer:close()
        end
        art.timer = nil
    end
end

--- Bump the generation and tell every viewer showing this artifact to refetch.
---@param art LvimPreviewArtifact
---@return nil
local function push_reload(art)
    art.generation = art.generation + 1
    art.status = { state = "ok" }
    server.broadcast({ type = "artifact", path = art.url_path, generation = art.generation })
end

--- Start watching an artifact's file for producer-less reloads.
---
--- The watcher is on the DIRECTORY, not the file: build tools routinely write to a temporary
--- name and rename over the target (latexmk does), which replaces the inode and silently ends a
--- file-scoped `fs_event` after the first build. Watching the directory and filtering by
--- basename survives that. The debounce coalesces the write burst of a single build.
---@param art LvimPreviewArtifact
---@return nil
local function start_watch(art)
    release_watch(art)
    local ev = uv.new_fs_event()
    if not ev then
        return
    end
    art.fs_event = ev
    art.timer = uv.new_timer()
    local ok = pcall(function()
        ev:start(art.dir, {}, function(err, filename)
            if err or filename ~= art.name then
                return
            end
            local t = art.timer
            if not t or t:is_closing() then
                return
            end
            t:stop()
            t:start(
                math.max(0, config.artifact.watch_debounce or 100),
                0,
                vim.schedule_wrap(function()
                    if state.artifacts[art.id] then
                        push_reload(art)
                    end
                end)
            )
        end)
    end)
    if not ok then
        release_watch(art)
    end
end

-- ── the handle ────────────────────────────────────────────────────────────

---@class LvimPreviewArtifactHandle
---@field id string  the producer's own id, echoed back
local Handle = {}
Handle.__index = Handle

--- Whether this handle still refers to a registered artifact on a running server.
---@return LvimPreviewArtifact?
function Handle:_live()
    local art = state.artifacts[self.id]
    if not art then
        return nil
    end
    if not server.is_running() then
        notify("preview server not running — the artifact page is unreachable", vim.log.levels.WARN)
        return nil
    end
    return art
end

--- The page URL of this artifact — what to open in a browser.
---@return string
function Handle:url()
    local art = state.artifacts[self.id]
    if not art then
        return ""
    end
    return ("http://%s:%d%s"):format(display_host(), state.port, art.url_path)
end

--- Signal that the produced file is NEW and coherent: bump the generation and tell every viewer
--- showing it to refetch. This is the call a build's success path makes.
---@return boolean ok  false when the artifact is gone or the server is not running
function Handle:reload()
    local art = self:_live()
    if not art then
        return false
    end
    push_reload(art)
    return true
end

--- Report producer state to the viewer. `"building"` raises a spinner over the LAST GOOD render
--- (nothing is refetched, so nothing flickers); `"error"` raises a strip carrying `message`;
--- `"ok"` clears the overlay. Full diagnostics belong in the editor, not on the page.
---@param st "idle"|"building"|"ok"|"error"
---@param message string?
---@return boolean ok
function Handle:status(st, message)
    local art = self:_live()
    if not art then
        return false
    end
    art.status = { state = st, message = message }
    server.broadcast({
        type = "status",
        path = art.url_path,
        state = st,
        message = message,
        stall_ms = config.artifact.stall_note_ms,
    })
    return true
end

--- Forward search: scroll the viewer to a point in the produced document and flash a highlight.
---
--- COORDINATE CONTRACT (pdf viewer): `page` is 1-based; `x` / `y` are PDF points measured from
--- the TOP-LEFT corner of that page — exactly what `synctex view` reports in its `x`/`y` fields.
--- `width` / `height` are optional, also in points, and default to a thin full-width band.
--- lvim-preview does no TeX resolution of its own: the producer computes the target.
---@param target { page: integer, x: number?, y: number?, width: number?, height: number? }
---@return boolean ok
function Handle:synctex(target)
    local art = self:_live()
    if not art or type(target) ~= "table" or not target.page then
        return false
    end
    server.broadcast({
        type = "synctex",
        path = art.url_path,
        page = target.page,
        x = target.x or 0,
        y = target.y or 0,
        width = target.width,
        height = target.height,
        highlight_ms = config.artifact.pdf.highlight_ms,
    })
    return true
end

--- Unregister the artifact. The server stops when this leaves nothing — no document and no other
--- artifact — previewed, mirroring what closing the last document does.
---@return nil
function Handle:close()
    local art = state.artifacts[self.id]
    if not art then
        return
    end
    release_watch(art)
    state.artifacts[art.id] = nil
    state.artifact_slugs[art.slug] = nil
    if state.count() == 0 and state.artifact_count() == 0 and server.is_running() then
        server.stop()
        notify("stopped")
    end
end

-- ── registry ──────────────────────────────────────────────────────────────

--- Register (or re-register) a produced file and get a handle to drive its viewer.
---
--- Starts the server when it is not already listening — this call is the artifact equivalent of
--- `:LvimPreview start`. The file itself need NOT exist yet: a producer registers before the
--- first build so the page can be opened and show "building".
---@param spec LvimPreviewArtifactSpec
---@return LvimPreviewArtifactHandle? handle, string? err
function M.register(spec)
    if type(spec) ~= "table" or type(spec.id) ~= "string" or spec.id == "" then
        return nil, "artifact spec needs a non-empty string id"
    end
    if type(spec.path) ~= "string" or spec.path == "" then
        return nil, "artifact spec needs a path"
    end
    local path = vim.fs.normalize(vim.fn.fnamemodify(spec.path, ":p"))
    local ext = path:match("%.([%w]+)$")
    local viewer = spec.viewer or (ext and EXT_VIEWER[ext:lower()]) or "raw"
    if not VIEWERS[viewer] then
        return nil, ('unknown viewer "%s" (pdf|html|raw)'):format(tostring(viewer))
    end

    -- Re-registration keeps the slug (and therefore the URL) and the generation, so tabs opened
    -- against an earlier registration of the same id stay valid across a producer restart.
    local prev = state.artifacts[spec.id]
    if not prev then
        state.artifact_seq = state.artifact_seq + 1
    end
    local name = vim.fn.fnamemodify(path, ":t")
    local slug = prev and prev.slug or ("a%d"):format(state.artifact_seq)
    if prev then
        release_watch(prev)
    end

    ---@type LvimPreviewArtifact
    local art = {
        id = spec.id,
        slug = slug,
        path = path,
        dir = vim.fs.normalize(vim.fn.fnamemodify(path, ":h")),
        name = name,
        viewer = viewer,
        title = spec.title or name,
        url_path = config.artifact.prefix .. slug .. "/",
        generation = prev and prev.generation or 1,
        status = prev and prev.status or { state = "idle" },
        watch = spec.watch == true,
        on_message = type(spec.on_message) == "function" and spec.on_message or nil,
        accepts = spec.accepts,
    }
    state.artifacts[art.id] = art
    state.artifact_slugs[art.slug] = art

    if not server.is_running() then
        local ok, err = server.start(config.address, config.port)
        if not ok then
            state.artifacts[art.id] = nil
            state.artifact_slugs[art.slug] = nil
            return nil, "could not start the server: " .. tostring(err)
        end
        local warn = not util.is_loopback(state.host) and "  (LAN-exposed, no auth)" or ""
        notify(("serving %s:%d%s"):format(display_host(), state.port, warn))
    end

    if art.watch then
        start_watch(art)
    end

    local handle = setmetatable({ id = art.id }, Handle)
    return handle
end

--- The handle for an already-registered id, or nil. Lets a producer that lost its handle (a
--- reloaded module) re-acquire one without re-registering.
---@param id string
---@return LvimPreviewArtifactHandle?
function M.handle(id)
    if not state.artifacts[id] then
        return nil
    end
    local handle = setmetatable({ id = id }, Handle)
    return handle
end

--- Every registered artifact, as a list of plain data — the public shape `:LvimPreview artifacts`
--- and any other consumer reads. Internal fields (`on_message`, the raw registry entry) are NOT
--- exposed: a caller that wants to act on one takes a `handle(id)`. Sorted by title for a stable
--- listing. Returns `{}` when nothing is registered.
---@return { id: string, title: string, name: string, path: string, url: string, viewer: string, state: string }[]
function M.list()
    local out = {}
    for id, art in pairs(state.artifacts) do
        out[#out + 1] = {
            id = id,
            title = art.title,
            name = art.name,
            path = art.path,
            url = ("http://%s:%d%s"):format(display_host(), state.port, art.url_path),
            viewer = art.viewer,
            state = (art.status and art.status.state) or "idle",
        }
    end
    table.sort(out, function(a, b)
        return (a.title or "") < (b.title or "")
    end)
    return out
end

--- Unregister every artifact (a full `:LvimPreview stop`). Does not stop the server itself —
--- the caller owns that teardown.
---@return nil
function M.close_all()
    for id, art in pairs(state.artifacts) do
        release_watch(art)
        state.artifact_slugs[art.slug] = nil
        state.artifacts[id] = nil
    end
end

--- Deliver one inbound viewer message to the artifact it addresses.
---
--- Called from the WebSocket read loop (a libuv fast context) ONLY when
--- `config.artifact.allow_client_messages` is on. The payload is JSON-decoded here (pure) and
--- the handler is invoked on the MAIN thread via vim.schedule, because a producer's handler will
--- want the editor API. A message that names no registered artifact, or one whose producer
--- supplied no `on_message`, is dropped — the passive-viewer rule still holds for everything
--- that did not explicitly opt in.
--- Does this artifact accept this message?
---
--- The gate is a promise about SHAPE, and until now it was one the framework left every producer to
--- keep for itself. That is the wrong place for it: a WebSocket connection is not tied to the page
--- it came from, so with the server LAN-bound any connected client can address any registered
--- artifact by its url path — and a producer that assumed the framework had already checked would be
--- handed whatever arrived. So the contract is declared per artifact (`accepts`, a list of type
--- names or a validator) and enforced HERE, once.
---
--- The built-in contract for a `viewer = "pdf"` artifact is the two SyncTeX shapes, with their
--- numbers checked for being finite and in range — NaN and infinity survive JSON decoding, and a
--- page of `-1` or `1/0` reaches `synctex` as a command-line argument.
---@param art table  the registry entry (`accepts`, `viewer`, `on_message`)
---@param msg table  the decoded frame
---@return boolean
function M.accepts(art, msg)
    local contract = art.accepts
    if type(contract) == "function" then
        return contract(msg) == true
    end
    --- Is `v` a real, finite number?
    ---@param v any
    ---@return boolean
    local function finite(v)
        return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
    end
    if type(contract) == "table" then
        return type(msg.type) == "string" and vim.tbl_contains(contract, msg.type)
    end
    if art.viewer == "pdf" then
        if msg.type ~= "synctex_edit" and msg.type ~= "synctex_scroll" then
            return false
        end
        return finite(msg.page) and msg.page >= 1 and finite(msg.x) and finite(msg.y)
    end
    -- A producer that registered a handler without declaring a contract gets what it always got, and
    -- the class doc says plainly that it is untrusted input.
    return true
end

---@param payload string  the raw text-frame payload
---@return nil
function M.dispatch_client_message(payload)
    local ok, msg = pcall(vim.json.decode, payload)
    if not ok or type(msg) ~= "table" or type(msg.path) ~= "string" then
        return
    end
    local art = state.artifact_for_url(msg.path)
    local handler = art and art.on_message
    if not handler then
        return
    end
    if not art or not M.accepts(art, msg) then
        return
    end
    vim.schedule(function()
        pcall(handler, msg)
    end)
end

return M
