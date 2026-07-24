-- lvim-preview: a live browser preview for Markdown / HTML / AsciiDoc / SVG, served by an
-- in-plugin pure-Lua (libuv) HTTP + WebSocket server with hot reload as you type. This module
-- is the public API + the `:LvimPreview` command surface; the heavy lifting is split out:
--   server/  — the uv TCP lifecycle, HTTP routing + traversal guard, the RFC 6455 handshake
--              (pure-Lua sha1) and frame codec, and the broadcast fan-out.
--   watch    — the previewed buffer's live-update autocmds (type-driven md/adoc/svg, save-driven
--              html) + the content cache the fast HTTP path serves.
--   scroll   — editor->browser sync scroll.
--   theme    — the palette-generated preview CSS, re-pushed on ColorScheme.
--   template — the served HTML shell; picker / browser — the chooser and the opener.
--
-- One server per Neovim instance; it is torn down on `:LvimPreview stop` and on VimLeavePre.
-- Loopback-only by default (see config.address); the browser is a passive viewer and never
-- drives the editor.
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
        local warn = not util.is_loopback(state.host) and "  (LAN-exposed, no auth)" or ""
        notify(("serving %s:%d%s"):format(display_host(), state.port, warn))
    end
    -- NOTE: no global `reload` broadcast here. The server already serves every registered
    -- document, so a new preview must not yank the tabs showing the others onto it.

    if config.auto_open then
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
--- previewed document) alive; the last one closed shuts the server down. Without it, stop
--- everything: detach all documents, drop the server and the hud chip.
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
        if state.count() > 0 then
            notify(("stopped %s (%d still previewing)"):format(vim.fn.fnamemodify(abs, ":t"), state.count()))
            return
        end
        -- that was the last document — fall through and shut the server down
    end
    watch.detach_all()
    scroll.detach_all()
    server.stop()
    state.docs = {}
    notify("stopped")
end

--- Re-open the browser: the current buffer's document when it is previewed, else the first one.
---@return nil
function M.open()
    if not server.is_running() or state.count() == 0 then
        notify("not running — start a preview first", vim.log.levels.WARN)
        return
    end
    local doc = state.doc_for_buf(vim.api.nvim_get_current_buf()) or state.list()[1]
    browser.open(preview_url(doc), config.browser)
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
        ("root    : %s"):format(state.root),
        ("clients : %d"):format(server.client_count()),
        ("theme   : %s"):format(config.theme),
    }
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
    vim.notify("lvim-preview\n" .. table.concat(lines, "\n"), vim.log.levels.INFO)
end

--- Whether the server is running.
---@return boolean
function M.is_running()
    return server.is_running()
end

-- ── command ───────────────────────────────────────────────────────────────

local SUBCOMMANDS = { "start", "stop", "open", "status", "pick" }

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
            M.open()
        elseif sub == "pick" then
            M.pick()
        elseif sub == "status" then
            M.status()
        else
            notify("unknown subcommand: " .. sub .. " (start|stop|open|status|pick)", vim.log.levels.WARN)
        end
    end, {
        nargs = "*",
        complete = function(arg, line)
            local words = vim.split(vim.trim(line), "%s+")
            if #words > 2 or (#words == 2 and arg == "") then
                if words[2] == "start" then
                    return vim.fn.getcompletion(arg, "file")
                end
                return {}
            end
            return vim.tbl_filter(function(c)
                return arg == "" or c:find(arg, 1, true) == 1
            end, SUBCOMMANDS)
        end,
        desc = "lvim-preview: start [file] | stop | open | status | pick",
    })
end

--- Configure the plugin. Idempotent — re-merges config and refreshes the theme; the command and
--- autocmds are registered once.
---@param opts? LvimPreviewConfig
---@return nil
function M.setup(opts)
    if ok_utils and utils.merge then
        utils.merge(config, opts or {})
    elseif opts then
        local merged = vim.tbl_deep_extend("force", config, opts)
        for k, v in pairs(merged) do
            config[k] = v
        end
    end

    theme.refresh()

    if registered then
        return
    end
    registered = true

    register_command()

    local grp = vim.api.nvim_create_augroup("lvim_preview", { clear = true })
    -- Live theme: rebuild the CSS and push it to every open tab so the page follows the editor.
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = grp,
        callback = function()
            theme.refresh_and_push()
        end,
    })
    pcall(function()
        require("lvim-utils.colors").on_change(function()
            theme.refresh_and_push()
        end)
    end)
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
