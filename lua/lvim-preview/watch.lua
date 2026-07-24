-- lvim-preview.watch: the live-update wiring of every previewed buffer. Two update models, per
-- the document kind:
--   * markdown / asciidoc / svg — push AS YOU TYPE. TextChanged/TextChangedI on that buffer
--     refresh its content cache and, debounced by config.debounce, broadcast an `update` frame;
--     the browser re-renders client-side. No save, no temp file.
--   * html — push on SAVE. A half-typed tag would thrash the DOM, so BufWritePost broadcasts a
--     `reload` and the browser refetches the page (and its own css/js/img) from the server.
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

local M = {}

---@type table<string, string>  doc path → its augroup name
local groups = {}
---@type table<string, uv.uv_timer_t>  doc path → its debounce timer
local timers = {}
---@type integer  augroup-name counter (a path is not a legal group name)
local seq = 0

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

--- Broadcast a document's cached content as an `update` frame (md/adoc/svg live render). The
--- `path` addresses it: tabs showing another document ignore the frame.
---@param doc LvimPreviewDoc
local function push_update(doc)
    server.broadcast({ type = "update", path = doc.url_path, content = doc.content or "" })
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

    if doc.filetype == "html" then
        -- Save-driven: refetch the page on write. A reload is per-tab (each refetches its own
        -- URL), so it is safe to broadcast even with other documents open.
        api.nvim_create_autocmd("BufWritePost", {
            group = grp,
            buffer = doc.bufnr,
            callback = function()
                server.broadcast({ type = "reload", path = doc.url_path })
            end,
        })
    else
        -- Type-driven: push on every change; also refresh + push on save (a formatter that
        -- rewrites the buffer on save fires BufWritePost, not always TextChanged).
        api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            group = grp,
            buffer = doc.bufnr,
            callback = function()
                on_text_changed(doc)
            end,
        })
        api.nvim_create_autocmd("BufWritePost", {
            group = grp,
            buffer = doc.bufnr,
            callback = function()
                refresh_content(doc)
                push_update(doc)
            end,
        })
    end
end

--- Remove ONE document's autocmds and stop its debounce timer.
---@param doc LvimPreviewDoc
---@return nil
function M.detach(doc)
    local name = groups[doc.file]
    if name then
        pcall(api.nvim_del_augroup_by_name, name)
        groups[doc.file] = nil
    end
    local t = timers[doc.file]
    if t and not t:is_closing() then
        t:stop()
    end
end

--- Detach every document (server stop / VimLeavePre).
---@return nil
function M.detach_all()
    for path, name in pairs(groups) do
        pcall(api.nvim_del_augroup_by_name, name)
        groups[path] = nil
    end
    for _, t in pairs(timers) do
        if t and not t:is_closing() then
            t:stop()
        end
    end
end

--- Release every debounce timer's libuv handle (VimLeavePre).
---@return nil
function M.dispose()
    M.detach_all()
    for path, t in pairs(timers) do
        if t and not t:is_closing() then
            t:close()
        end
        timers[path] = nil
    end
end

return M
