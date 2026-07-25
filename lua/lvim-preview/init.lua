-- lvim-preview: a live browser preview for Markdown and org, served by an in-plugin pure-Lua
-- (libuv) HTTP + WebSocket server with hot reload as you type. This module is the public API +
-- the `:LvimPreview` command surface; the heavy lifting is split out:
--   server/  — the uv TCP lifecycle, HTTP routing + traversal guard, the RFC 6455 handshake
--              (pure-Lua sha1) and frame codec, and the broadcast fan-out.
--   watch    — the previewed buffer's live-update autocmds (type-driven md/org) + the content
--              cache the fast HTTP path serves.
--   scroll   — sync scroll: editor->browser always, browser->editor when opted in.
--   theme    — the palette-generated preview CSS, re-pushed on ColorScheme.
--   template — the served HTML shells; picker / browser — the chooser and the opener.
--   artifact — the PRODUCER seam: a file another plugin builds, served and reloaded on its
--              signal (see `M.register_artifact`).
--
-- Two sources of truth, deliberately kept apart: a DOCUMENT is a buffer this plugin renders in
-- the browser, an ARTIFACT is a file an external toolchain produces and this plugin only
-- displays. Both keep the one server alive; it stops when the last of either closes.
--
-- One server per Neovim instance; it is torn down on `:LvimPreview stop` and on VimLeavePre.
-- Loopback-only by default (see config.address); the browser is a passive viewer and never drives
-- the editor unless one of the two opt-in gates is switched on — artifact inverse search
-- (artifact.lua) and browser->editor sync scroll (scroll.lua). Both are off by default and each
-- accepts only its own message shape; the gate itself lives in server/init.lua's `on_ws_bytes`.
--
---@module "lvim-preview"

local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local util = require("lvim-preview.util")
local server = require("lvim-preview.server")
local watch = require("lvim-preview.watch")
local scroll = require("lvim-preview.scroll")
local theme = require("lvim-preview.theme")
local browser = require("lvim-preview.browser")
local picker = require("lvim-preview.picker")
local artifact = require("lvim-preview.artifact")
local export = require("lvim-preview.export")
local qr = require("lvim-preview.qr")
local tunnel = require("lvim-preview.tunnel")

local ok_utils, utils = pcall(require, "lvim-utils.utils")

local M = {}

---@type boolean  one-time setup (command + autocmds) done
local registered = false

-- Root markers used when config.root = "project".
local ROOT_MARKERS =
    { ".git", ".hg", ".svn", ".lvim", "package.json", "Cargo.toml", "go.mod", "Makefile", "pyproject.toml" }

--- Notify helper, gated by config.notify.
---@param msg string
---@param level integer?
local function notify(msg, level)
    if config.notify then
        vim.notify("lvim-preview: " .. msg, level or vim.log.levels.INFO)
    end
end

--- Is `bufnr` (default: the current buffer) one of the documents this server is previewing?
--- Public, framework-agnostic — a statusline / winbar of any kind can gate on it.
---@param bufnr integer?
---@return boolean
function M.is_previewing(bufnr)
    if not server.is_running() then
        return false
    end
    return state.doc_for_buf(bufnr or vim.api.nvim_get_current_buf()) ~= nil
end

--- The plain "serving" text for `bufnr` — `""` when that buffer is not previewed, so a statusline
--- can concatenate it unconditionally. No highlight markup: any framework can render it its own
--- way (`hud_segment` below wraps this for the lvim-hud chrome).
---@param bufnr integer?
---@return string
function M.status_text(bufnr)
    if not M.is_previewing(bufnr) then
        return ""
    end
    return ("%s :%d"):format(config.icons.server or "", state.port)
end

--- A ready-made lvim-hud chrome SEGMENT for the "serving" indicator — drop it into a statusline /
--- winbar segment list (the lvim-breadcrumbs `hud_segment` pattern).
---
--- It renders ONLY in a buffer that is actually being previewed, so the marker follows the cursor:
--- move to an unrelated file and it disappears. This deliberately does NOT use `lvim-hud.overlay` —
--- that is the transient ECHO area, which the statusline shows INSTEAD of the file segments, so
--- holding it for the server's whole lifetime blanked the real statusline (path / git / LSP) the
--- entire time a preview was open.
---@param opts { name?: string, inactive?: boolean }?
---@return table  LvimChromeSegment
function M.hud_segment(opts)
    opts = opts or {}
    return {
        name = opts.name or "preview",
        when = function(ctx)
            if not config.hud_chip then
                return false
            end
            if not (opts.inactive or ctx.active) then
                return false
            end
            return M.is_previewing(ctx.buf)
        end,
        content = function(ctx)
            local ok, parts = pcall(require, "lvim-hud.chrome.parts")
            local text = " " .. M.status_text(ctx.buf) .. " "
            return ok and parts.seg("Green", text) or text
        end,
    }
end

--- Resolve the servable root for a previewed file per config.root.
---@param file string  absolute file path
---@return string root  absolute, normalised
local function resolve_root(file)
    local r = config.root
    if r == "file" then
        return vim.fs.normalize(vim.fn.fnamemodify(file, ":h"))
    elseif r == "project" then
        local found = vim.fs.root(file, ROOT_MARKERS)
        return vim.fs.normalize(found or vim.fn.getcwd())
    end
    -- explicit path
    return vim.fs.normalize(vim.fn.fnamemodify(r, ":p"))
end

--- The URL path of `abs` relative to `root` (leading "/"), or nil when `abs` is not under it.
---@param abs string
---@param root string
---@return string?
local function url_path_of(abs, root)
    abs, root = vim.fs.normalize(abs), vim.fs.normalize(root)
    if abs == root then
        return "/"
    end
    if abs:sub(1, #root + 1) == root .. "/" then
        return abs:sub(#root + 1) -- keeps the leading "/"
    end
    return nil
end

--- The address the LOCAL browser should hit (0.0.0.0 → loopback for the opener).
---@return string
local function display_host()
    if state.host == "0.0.0.0" or state.host == "::" then
        return "127.0.0.1"
    end
    return state.host
end

--- The full preview URL of one document (the root when none is given).
---@param doc LvimPreviewDoc?
---@return string
local function preview_url(doc)
    return ("http://%s:%d%s"):format(display_host(), state.port, doc and doc.url_path or "/")
end

--- The host another device on the LAN can reach the server at (nil when the bind is loopback-only,
--- so nothing off this machine can connect). A wildcard bind (0.0.0.0 / ::) answers on every
--- interface → the first detected LAN IPv4; an explicit non-loopback bind is itself the address.
---@return string?
local function lan_host()
    if util.is_loopback(state.host) then
        return nil
    end
    if state.host == "0.0.0.0" or state.host == "::" then
        return util.lan_ipv4()[1]
    end
    return state.host
end

--- The URL another device should use for the preview: the explicit `public_url` when set (a tunnel
--- or forwarded IP — reachable from anywhere), else the LAN address when the server is exposed, else
--- the loopback URL (only this machine can open it — the caller says so).
---@param doc LvimPreviewDoc?
---@return string url, boolean remote  -- `remote` = reachable from another device
local function reachable_url(doc)
    local path = doc and doc.url_path or "/"
    -- A captured auto-tunnel URL (runtime) wins over a statically configured one.
    local pub = state.tunnel_url or config.public_url
    if type(pub) == "string" and pub ~= "" then
        return (pub:gsub("/+$", "")) .. path, true
    end
    local host = lan_host()
    if host then
        return ("http://%s:%d%s"):format(host, state.port, path), true
    end
    return preview_url(doc), false
end

--- Show a scannable QR of `url` in a centred, themed lvim-ui window (fixed black/white cells so it
--- scans under any editor theme). `note` is an optional caption line (e.g. the loopback caveat).
--- `enter` focuses it so `q` closes immediately; false leaves the cursor in the editor.
---@param url string
---@param note string?
---@param enter boolean
---@return nil
local function show_qr(url, note, enter)
    local matrix, meta = qr.encode(url)
    if not matrix then
        notify(("cannot build a QR for %s (%s)"):format(url, tostring(meta)), vim.log.levels.WARN)
        return
    end
    ---@cast meta LvimPreviewQrMeta
    qr.define_highlights()
    local lines, highlights = qr.render(matrix, meta.size)
    local width = vim.fn.strdisplaywidth(lines[1] or "")
    -- Caption rows below the code (blank spacer, URL, optional note), centred under the QR. They live
    -- AFTER the QR rows, so the QR's own highlight row indices stay valid.
    local function centred(s)
        local pad = math.max(0, math.floor((width - vim.fn.strdisplaywidth(s)) / 2))
        return string.rep(" ", pad) .. s
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = centred(url)
    if note then
        lines[#lines + 1] = centred(note)
    end
    local ok_ui, ui = pcall(require, "lvim-ui")
    if not ok_ui then
        notify("scan to open: " .. url) -- lvim-ui absent → the URL is still actionable
        return
    end
    ui.info(lines, {
        title = "Scan to open",
        highlights = highlights,
        enter = enter,
        hide_cursor = true,
    })
end

--- Announce an EXPOSED start — the bind is non-loopback (raw LAN, no auth) and/or a `public_url` is
--- configured (a tunnel/forwarded address). `lan.warn` controls the notice, `lan.qr` the scannable
--- QR. A raw LAN bind gets the loud no-auth warning + every reachable URL; a loopback+public_url
--- (tunnel) start just advertises the public URL. `doc` scopes the URL to the file.
---@param doc LvimPreviewDoc?
---@return nil
local function announce_exposure(doc)
    local lan = config.lan or {}
    local url = select(1, reachable_url(doc))
    local raw_lan = not util.is_loopback(state.host) -- the bind itself exposes the LAN with no auth
    if lan.warn ~= false then
        if raw_lan then
            local urls = {}
            for _, ip in ipairs(util.lan_ipv4()) do
                urls[#urls + 1] = ("http://%s:%d%s"):format(ip, state.port, doc and doc.url_path or "/")
            end
            local where = #urls > 0 and table.concat(urls, "\n  ") or url
            notify(
                "serving on a NON-loopback address — the preview and every file under the root are "
                    .. "reachable by any host on the network, with NO authentication. Reachable at:\n  "
                    .. where,
                vim.log.levels.WARN
            )
        else
            -- Loopback bind behind a configured public_url (a tunnel/proxy adds its own TLS + auth).
            notify(("also reachable publicly at %s (public_url)"):format(url))
        end
    end
    if lan.qr ~= false then
        show_qr(url, nil, true)
    end
end

--- Ensure a loaded buffer exists for `file` (so the live-update autocmds can attach), returning
--- its bufnr. Reuses the current buffer / an existing one; loads the file otherwise.
---@param file string
---@return integer bufnr
local function ensure_buffer(file)
    local buf = vim.fn.bufnr(file)
    if buf == -1 then
        buf = vim.fn.bufadd(file)
    end
    if not vim.api.nvim_buf_is_loaded(buf) then
        vim.fn.bufload(buf)
    end
    return buf
end

--- Preview a specific file: resolve root + URL, attach the live-update + scroll autocmds, start
--- the server if needed, and (auto_open) open the browser. The one entry point every command /
--- picker path funnels through.
---@param file string  a path (any form); resolved to absolute here
---@return boolean ok
function M.preview_file(file)
    local abs = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
    local kind = util.kind_for(abs)
    if not kind then
        notify(("not a previewable file: %s"):format(vim.fn.fnamemodify(abs, ":t")), vim.log.levels.WARN)
        return false
    end
    if vim.fn.filereadable(abs) == 0 then
        notify(("file not found: %s"):format(abs), vim.log.levels.ERROR)
        return false
    end

    -- The servable root is SERVER-level: once listening it is fixed, so a second document must
    -- live under it (otherwise it could not be addressed by a URL at all). Only the first preview
    -- resolves a root; a later file outside it gets a clear error instead of a broken page.
    local root = (server.is_running() and state.root ~= "") and state.root or resolve_root(abs)
    local up = url_path_of(abs, root)
    if not up then
        notify(
            ('file is outside the servable root (%s); set root = "file" or an enclosing path'):format(root),
            vim.log.levels.ERROR
        )
        return false
    end

    state.root = root
    -- Register (or refresh) the document — previewing another file JOINS the live set instead of
    -- replacing it, so every already-open tab keeps updating from its own buffer.
    ---@type LvimPreviewDoc
    local doc = state.docs[abs] or {}
    doc.file = abs
    doc.filetype = kind
    doc.url_path = up
    doc.bufnr = ensure_buffer(abs)
    state.docs[abs] = doc

    theme.refresh() -- make sure the cached theme CSS matches the current palette
    watch.attach(doc)
    scroll.attach(doc)

    if not server.is_running() then
        local ok, err = server.start(config.address, config.port)
        if not ok then
            notify("could not start the server: " .. tostring(err), vim.log.levels.ERROR)
            return false
        end
        local pub = config.public_url
        if (config.tunnel or {}).enabled then
            -- The tunnel assigns the public URL asynchronously; announce (WARN/QR) once it is captured.
            notify(("serving %s:%d — opening tunnel…"):format(display_host(), state.port))
            tunnel.ensure(state.port, function()
                announce_exposure(doc)
            end)
        elseif not util.is_loopback(state.host) or (type(pub) == "string" and pub ~= "") then
            announce_exposure(doc) -- WARN/notice + reachable URL(s) + the scannable QR (config `lan`)
        else
            notify(("serving %s:%d"):format(display_host(), state.port))
        end
    end
    -- NOTE: no global `reload` broadcast here. The server already serves every registered
    -- document, so a new preview must not yank the tabs showing the others onto it.

    -- Auto-open, UNLESS a collision with another Neovim just bumped us to a different port: opening
    -- a tab there would look like success while showing a second, unwanted server. Hand over the URL
    -- so the user opens it deliberately if that is really what they want.
    if state.collided_port then
        notify(
            ("this buffer's preview is at %s — open it by hand if you want a second server"):format(preview_url(doc))
        )
    elseif config.auto_open then
        browser.open(preview_url(doc), config.browser)
    end
    return true
end

--- Start previewing `file` (or the current buffer's file when omitted).
---@param file string?
---@return nil
function M.start(file)
    local target = file
    if not target or target == "" then
        target = vim.api.nvim_buf_get_name(0)
        if target == "" then
            notify("no file in the current buffer — pass a path or open a file first", vim.log.levels.WARN)
            return
        end
    end
    M.preview_file(target)
end

--- Stop previewing. With `file`, close only THAT document and keep the server (and every other
--- previewed document, and every registered artifact) alive; the last thing closed shuts the
--- server down. Without it, stop everything: detach all documents, unregister every artifact,
--- drop the server and the hud chip.
---@param file string?  path of a single document to stop previewing
---@return nil
function M.stop(file)
    if not server.is_running() then
        notify("not running")
        return
    end
    if file and file ~= "" then
        local abs = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
        local doc = state.doc(abs)
        if not doc then
            notify(("not previewed: %s"):format(vim.fn.fnamemodify(abs, ":t")), vim.log.levels.WARN)
            return
        end
        watch.detach(doc)
        scroll.detach(doc)
        state.docs[abs] = nil
        -- A registered artifact is reason enough to keep serving: its producer holds a handle
        -- and expects `reload()` to keep working after the last document was closed.
        local left = state.count() + state.artifact_count()
        if left > 0 then
            notify(("stopped %s (%d still served)"):format(vim.fn.fnamemodify(abs, ":t"), left))
            return
        end
        -- that was the last thing served — fall through and shut the server down
    end
    watch.detach_all()
    scroll.detach_all()
    artifact.close_all()
    tunnel.stop() -- kill the auto-tunnel process, if one is up
    server.stop()
    state.docs = {}
    notify("stopped")
end

--- Register a produced FILE for serving + live reload, and get a handle that drives its viewer.
---
--- This is the seam for a plugin that COMPILES something (a LaTeX build, a diagram export, a
--- static-site generator): it owns the toolchain and the build lifecycle, lvim-preview owns the
--- display. The producer calls `handle:status("building")` when a build starts and
--- `handle:reload()` when it finished coherently; nothing else is needed.
---
--- See `lvim-preview.artifact` for the spec / handle contract and the coordinate convention of
--- `handle:synctex`.
---@param spec LvimPreviewArtifactSpec
---@return LvimPreviewArtifactHandle? handle, string? err
function M.register_artifact(spec)
    local handle, err = artifact.register(spec)
    if not handle then
        notify("could not register the artifact: " .. tostring(err), vim.log.levels.ERROR)
    end
    return handle, err
end

--- The handle for an already-registered artifact id, or nil.
---@param id string
---@return LvimPreviewArtifactHandle?
function M.artifact(id)
    return artifact.handle(id)
end

--- Re-open the browser: the current buffer's document when it is previewed, else the first
--- document, else the first registered artifact (a server may be serving only artifacts).
---@return nil
--- Open a served page in the browser. With no argument: the current buffer's preview (or the first
--- document, else the first artifact). With an artifact `id`: that artifact — the addressable half
--- of `artifacts` below, so a producer-registered document (a built PDF, an HTML render) is reachable
--- by name from the command line, not only through the producer's own handle.
---@param id? string  an artifact id (from `:LvimPreview artifacts`); nil = the current document
---@return nil
function M.open(id)
    if not server.is_running() then
        notify("not running — start a preview first", vim.log.levels.WARN)
        return
    end
    if id and id ~= "" then
        local h = require("lvim-preview.artifact").handle(id)
        if not h then
            notify(("no artifact with id %q — see :LvimPreview artifacts"):format(id), vim.log.levels.WARN)
            return
        end
        browser.open(h:url(), config.browser)
        return
    end
    local doc = state.doc_for_buf(vim.api.nvim_get_current_buf()) or state.list()[1]
    if doc then
        browser.open(preview_url(doc), config.browser)
        return
    end
    local art = state.artifact_list()[1]
    if not art then
        notify("nothing is being served — start a preview first", vim.log.levels.WARN)
        return
    end
    browser.open(("http://%s:%d%s"):format(display_host(), state.port, art.url_path), config.browser)
end

--- List the registered artifacts through the canonical picker; choosing one opens it. Artifacts are
--- produced by OTHER plugins (a LaTeX build's PDF, an HTML render) and were reachable only through
--- the producer's handle until now — this makes them visible and openable from the editor.
---@return nil
function M.artifacts()
    if not server.is_running() then
        notify("not running — no server to hold artifacts", vim.log.levels.WARN)
        return
    end
    local arts = require("lvim-preview.artifact").list()
    if #arts == 0 then
        notify("no artifacts registered (a producer plugin registers them; none has)", vim.log.levels.INFO)
        return
    end
    local items = {}
    for _, a in ipairs(arts) do
        items[#items + 1] = {
            -- title, then the viewer kind and live state as trailing context, then the source path.
            label = ("%s  [%s · %s]  %s"):format(a.title, a.viewer, a.state, vim.fn.fnamemodify(a.path, ":~")),
            icon = config.icons.file,
            id = a.id,
        }
    end
    require("lvim-ui").select({
        title = "Artifacts",
        items = items,
        callback = function(confirmed, index)
            if confirmed and index then
                M.open(items[index].id)
            end
        end,
    })
end

--- Show a QR of the current preview URL so a phone on the LAN can open it without typing an IP.
--- Uses the reachable LAN address when the server is exposed; on a loopback-only bind it shows the
--- loopback URL with a note that only this machine can reach it (bind a LAN `address` to use a phone).
---@return nil
function M.qr()
    if not server.is_running() then
        notify("not running — start a preview first", vim.log.levels.WARN)
        return
    end
    local doc = state.doc_for_buf(vim.api.nvim_get_current_buf()) or state.list()[1]
    local url, lan = reachable_url(doc)
    show_qr(url, lan and nil or "loopback only — reachable from this machine, not a phone", true)
end

--- The root to scan for the chooser: the live server's root while running, else the root of the
--- current file (or the cwd when the buffer has no file).
---@return string
local function pick_root()
    if server.is_running() and state.root ~= "" then
        return state.root
    end
    local file = vim.api.nvim_buf_get_name(0)
    if file ~= "" then
        return resolve_root(file)
    end
    -- No file to anchor on: an explicit root wins, otherwise scan the cwd.
    if config.root ~= "project" and config.root ~= "file" then
        return vim.fs.normalize(vim.fn.fnamemodify(config.root, ":p"))
    end
    return vim.fs.normalize(vim.fn.getcwd())
end

--- Open the file chooser (lvim-ui select) and preview the pick.
---@return nil
function M.pick()
    picker.pick(pick_root(), function(path)
        M.preview_file(path)
    end)
end

--- Export the current buffer to a self-contained static HTML file (offline snapshot). Independent
--- of the live server — it renders the buffer, inlines the CSS + only the render libraries the
--- document uses (with their fonts as data: URIs), and writes one file. See `lvim-preview.export`.
---@param path string?  optional output path (a file, or a directory to write the default name into)
---@return nil
function M.export(path)
    export.run(path)
end

--- Report the current server / preview status via a notification.
---@return nil
function M.status()
    if not server.is_running() then
        vim.notify("lvim-preview: stopped", vim.log.levels.INFO)
        return
    end
    local lines = {
        ("address : http://%s:%d"):format(display_host(), state.port),
        ("bind    : %s%s"):format(
            state.host,
            util.is_loopback(state.host) and " (loopback)" or " (LAN-exposed, NO AUTH)"
        ),
    }
    if type(config.public_url) == "string" and config.public_url ~= "" then
        lines[#lines + 1] = ("public  : %s"):format(config.public_url)
    end
    vim.list_extend(lines, {
        ("root    : %s  (serve = %s)"):format(state.root, config.serve),
        ("clients : %d"):format(server.client_count()),
        ("theme   : %s"):format(config.theme),
    })
    -- Every previewed document, not just one: the set is what the server is serving.
    local docs = state.list()
    lines[#lines + 1] = ("files   : %d"):format(#docs)
    for _, doc in ipairs(docs) do
        lines[#lines + 1] = ("  %s  →  %s  (%s)"):format(
            vim.fn.fnamemodify(doc.file, ":."),
            doc.url_path,
            doc.filetype
        )
    end
    -- Registered artifacts are served alongside the documents and keep the server alive too.
    local arts = state.artifact_list()
    if #arts > 0 then
        lines[#lines + 1] = ("artifacts: %d"):format(#arts)
        for _, art in ipairs(arts) do
            lines[#lines + 1] = ("  %s  →  %s  (%s, gen %d, %s)"):format(
                art.id,
                art.url_path,
                art.viewer,
                art.generation,
                art.status.state
            )
        end
    end
    vim.notify("lvim-preview\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Whether the server is running.
---@return boolean
function M.is_running()
    return server.is_running()
end

-- ── command ───────────────────────────────────────────────────────────────

local SUBCOMMANDS = { "start", "stop", "open", "artifacts", "qr", "status", "pick", "export" }

--- Register the :LvimPreview command (once).
---@return nil
local function register_command()
    vim.api.nvim_create_user_command("LvimPreview", function(cmd)
        local sub = cmd.fargs[1] or "status"
        if sub == "start" then
            M.start(cmd.fargs[2])
        elseif sub == "stop" then
            M.stop(cmd.fargs[2]) -- optional path: stop ONE document, keep the rest previewing
        elseif sub == "open" then
            M.open(cmd.fargs[2]) -- optional artifact id
        elseif sub == "artifacts" then
            M.artifacts()
        elseif sub == "qr" then
            M.qr()
        elseif sub == "pick" then
            M.pick()
        elseif sub == "export" then
            M.export(cmd.fargs[2]) -- optional output path (file or directory)
        elseif sub == "status" then
            M.status()
        else
            notify(
                "unknown subcommand: " .. sub .. " (start|stop|open|artifacts|qr|status|pick|export)",
                vim.log.levels.WARN
            )
        end
    end, {
        nargs = "*",
        complete = function(arg, line)
            local words = vim.split(vim.trim(line), "%s+")
            if #words > 2 or (#words == 2 and arg == "") then
                -- Both `start` and `export` take a path argument — complete it against the fs.
                if words[2] == "start" or words[2] == "export" then
                    return vim.fn.getcompletion(arg, "file")
                end
                if words[2] == "open" then
                    -- the artifact ids, so `:LvimPreview open <Tab>` completes what can be opened
                    local ids = {}
                    for _, a in ipairs(require("lvim-preview.artifact").list()) do
                        if arg == "" or a.id:find(arg, 1, true) == 1 then
                            ids[#ids + 1] = a.id
                        end
                    end
                    return ids
                end
                return {}
            end
            return vim.tbl_filter(function(c)
                return arg == "" or c:find(arg, 1, true) == 1
            end, SUBCOMMANDS)
        end,
        desc = "lvim-preview: start [file] | stop | open [artifact-id] | artifacts | qr | status | pick | export [path]",
    })
end

--- Configure the plugin. Idempotent — re-merges config and refreshes the theme; the command and
--- autocmds are registered once.
---@param opts? LvimPreviewConfig
---@return nil
function M.setup(opts)
    -- The ecosystem's merge semantics (dicts merge, LISTS replace wholesale). lvim-utils owns
    -- the shared implementation; util.merge is its byte-for-byte fallback for a runtime without
    -- it, so both paths behave identically — `vim.tbl_deep_extend` does NOT (it index-merges
    -- arrays, leaving the tail of a default list behind an override).
    local merge = (ok_utils and utils.merge) or util.merge
    merge(config, opts or {})

    theme.refresh()

    if registered then
        return
    end
    registered = true

    register_command()

    local grp = vim.api.nvim_create_augroup("lvim_preview", { clear = true })
    -- Live theme: rebuild the CSS (base palette vars + the editor's tree-sitter code colours) and
    -- push it to every open tab, so the page — document AND syntax colours — follows the editor with
    -- no reload and no re-run of :LvimPreview. TWO events, the same seam lvim-utils.highlight uses:
    --   * native `ColorScheme` — a plain `:colorscheme` (a third-party theme, or lvim-colorscheme's
    --     own restore path that goes through `:colorscheme`).
    --   * `User LvimColorscheme` — how lvim-colorscheme ACTUALLY applies its themes, INCLUDING the
    --     picker's live-preview variant switches: it sets the highlights directly and fires this
    --     event, it does NOT go through native `ColorScheme`. Listening only for `ColorScheme` would
    --     leave the browser one theme behind on every palette change made the way the user makes it.
    -- refresh_and_push reads the NEW colours either way: lvim-colorscheme applies the highlights
    -- BEFORE firing the event, so nvim_get_hl (the code + heading colours) is always current.
    local function repush()
        theme.refresh_and_push()
    end
    vim.api.nvim_create_autocmd("ColorScheme", { group = grp, callback = repush })
    vim.api.nvim_create_autocmd("User", { group = grp, pattern = "LvimColorscheme", callback = repush })
    -- Complete teardown on exit — no orphaned port, no leaked timer handle.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = grp,
        callback = function()
            if server.is_running() then
                server.stop()
            end
            watch.dispose()
        end,
    })
end

return M
