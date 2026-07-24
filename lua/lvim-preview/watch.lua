-- lvim-preview.watch: the live-update wiring of every previewed buffer. One update model, for the
-- two kinds that remain previewable: markdown and org push AS YOU TYPE. TextChanged/TextChangedI
-- on that buffer refresh its content cache and, debounced by config.debounce, broadcast an
-- `update` frame carrying the finished HTML (both renderers are ours and run here). The page
-- replaces its content in place — no save, no temp file, no reload.
--
-- PER DOCUMENT, not per session: each previewed file owns its augroup and its debounce timer, so
-- any number of documents stay live at once and previewing a new one never detaches the others.
-- Every frame carries that document's `url_path`, and the client applies only the frames matching
-- the page it shows — so one broadcast keeps N tabs, each on a different file, correct.
--
-- A document's content cache (doc.content) is refreshed here on the MAIN thread so the fast HTTP
-- path can serve the unsaved buffer on first paint.
--
---@module "lvim-preview.watch"

local api = vim.api
local uv = vim.uv
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local server = require("lvim-preview.server")
local template = require("lvim-preview.template")

local M = {}

---@type table<string, string>  doc path → its augroup name
local groups = {}
---@type table<string, uv.uv_timer_t>  doc path → its debounce timer
local timers = {}
---@type integer  augroup-name counter (a path is not a legal group name)
local seq = 0

--- Release ONE document's debounce timer: stop it AND close the libuv handle, then forget it.
--- `stop()` alone leaves the handle open and the registry entry behind, so a preview/stop cycle
--- repeated N times used to hold N live uv_timer_t handles until VimLeavePre.
---@param path string  the document's absolute path (the timer registry key)
---@return nil
local function release_timer(path)
    local t = timers[path]
    if t then
        if not t:is_closing() then
            t:stop()
            t:close()
        end
        timers[path] = nil
    end
end

--- Read a document's buffer into its content cache. Main thread only.
---@param doc LvimPreviewDoc
---@return string
local function refresh_content(doc)
    local buf = doc.bufnr
    if buf and api.nvim_buf_is_valid(buf) then
        doc.content = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    return doc.content or ""
end

M.refresh_content = refresh_content

--- Broadcast a document's cached content as an `update` frame. The `path` addresses it: tabs
--- showing another document ignore the frame.
---
--- Both previewable kinds (markdown, org) are rendered in Lua here, so the frame carries finished
--- HTML and `server_rendered = true`; the client places it instead of running a renderer. Same
--- function the HTTP shell uses, so first paint and every live update can never disagree.
---@param doc LvimPreviewDoc
local function push_update(doc)
    local content = doc.content or ""
    local rendered = template.server_render(doc.filetype, content)
    server.broadcast({
        type = "update",
        path = doc.url_path,
        content = rendered or content,
        server_rendered = rendered ~= nil,
    })
end

--- Debounced type-driven push for ONE document: refresh its cache now (so an immediate reconnect
--- serves fresh text), then coalesce its broadcast over config.debounce ms. Each document keeps
--- its own timer, so typing in one never cancels another's pending push.
---@param doc LvimPreviewDoc
local function on_text_changed(doc)
    refresh_content(doc)
    local t = timers[doc.file]
    if not t then
        t = uv.new_timer()
        timers[doc.file] = t
    end
    t:stop()
    t:start(
        math.max(0, config.debounce or 100),
        0,
        vim.schedule_wrap(function()
            push_update(doc)
        end)
    )
end

--- Attach the live-update autocmds for one document. Idempotent: re-attaching the same document
--- clears only ITS augroup, never another document's.
---@param doc LvimPreviewDoc
---@return nil
function M.attach(doc)
    M.detach(doc)
    refresh_content(doc)
    seq = seq + 1
    local name = "LvimPreviewWatch_" .. seq
    groups[doc.file] = name
    local grp = api.nvim_create_augroup(name, { clear = true })
    -- Watch the FILE, not a fixed bufnr. lvim-space (and `:edit`, a session restore, a buffer
    -- reload) recreates the buffer for a file under a NEW number; a buffer-scoped autocmd would be
    -- stranded on the dead handle and live updates would silently die until `:LvimPreview` was
    -- restarted. A `pattern` autocmd re-matches on every event, so whichever buffer currently holds
    -- the file is the one that fires; the callback re-reads the live bufnr from the event so the
    -- content cache follows the file rather than a stale handle.
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = grp,
        pattern = doc.file,
        callback = function(ev)
            doc.bufnr = ev.buf
            on_text_changed(doc)
        end,
    })
end

--- Remove ONE document's autocmds and release its debounce timer.
---@param doc LvimPreviewDoc
---@return nil
function M.detach(doc)
    local name = groups[doc.file]
    if name then
        pcall(api.nvim_del_augroup_by_name, name)
        groups[doc.file] = nil
    end
    release_timer(doc.file)
end

--- Detach every document (server stop / VimLeavePre). Attaching again re-creates both the
--- augroup and the timer, so releasing here leaves nothing behind.
---@return nil
function M.detach_all()
    for path, name in pairs(groups) do
        pcall(api.nvim_del_augroup_by_name, name)
        groups[path] = nil
    end
    for path in pairs(timers) do
        release_timer(path)
    end
end

--- Full teardown (VimLeavePre). Identical to detach_all now that detaching releases the
--- handles; kept as the named exit hook init.lua calls.
---@return nil
function M.dispose()
    M.detach_all()
end

return M
