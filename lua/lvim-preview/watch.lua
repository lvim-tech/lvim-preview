-- lvim-preview.watch: the previewed buffer's live-update wiring. Two update models, per the
-- document kind:
--   * markdown / asciidoc / svg — push AS YOU TYPE. TextChanged/TextChangedI on the previewed
--     buffer refresh the content cache and, debounced by config.debounce, broadcast an `update`
--     frame; the browser re-renders client-side. No save, no temp file.
--   * html — push on SAVE. A half-typed tag would thrash the DOM, so BufWritePost broadcasts a
--     `reload` and the browser refetches the page (and its own css/js/img) from the server.
--
-- The content cache (state.content) is refreshed here on the MAIN thread so the fast HTTP path
-- can serve the unsaved buffer on first paint. Everything is scoped to one buffer via a cleared
-- augroup, so re-previewing another file detaches cleanly.
--
---@module "lvim-preview.watch"

local api = vim.api
local uv = vim.uv
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local server = require("lvim-preview.server")

local M = {}

local AUGROUP = "LvimPreviewWatch"

---@type uv.uv_timer_t?  debounce timer for type-driven pushes
local timer = nil

--- Read the previewed buffer's full text into the content cache. Main thread only.
---@return string
local function refresh_content()
    local buf = state.bufnr
    if buf and api.nvim_buf_is_valid(buf) then
        state.content = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    return state.content or ""
end

M.refresh_content = refresh_content

--- Broadcast the current cached content as an `update` frame (md/adoc/svg live render).
local function push_update()
    server.broadcast({ type = "update", path = state.url_path, content = state.content or "" })
end

--- Debounced type-driven push: refresh the cache now (so an immediate reconnect serves fresh
--- text), then coalesce the broadcast over config.debounce ms.
local function on_text_changed()
    refresh_content()
    if not timer then
        timer = uv.new_timer()
    end
    timer:stop()
    timer:start(math.max(0, config.debounce or 100), 0, vim.schedule_wrap(push_update))
end

--- Attach the live-update autocmds to the previewed buffer. `filetype` selects the model.
---@param bufnr integer
---@param filetype string  "markdown"|"asciidoc"|"svg"|"html"
---@return nil
function M.attach(bufnr, filetype)
    M.detach()
    state.bufnr = bufnr
    refresh_content()
    local grp = api.nvim_create_augroup(AUGROUP, { clear = true })

    if filetype == "html" then
        -- Save-driven: refetch the page on write.
        api.nvim_create_autocmd("BufWritePost", {
            group = grp,
            buffer = bufnr,
            callback = function()
                server.broadcast({ type = "reload" })
            end,
        })
    else
        -- Type-driven: push on every change; also refresh + push on save (a formatter that
        -- rewrites the buffer on save fires BufWritePost, not always TextChanged).
        api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
            group = grp,
            buffer = bufnr,
            callback = on_text_changed,
        })
        api.nvim_create_autocmd("BufWritePost", {
            group = grp,
            buffer = bufnr,
            callback = function()
                refresh_content()
                push_update()
            end,
        })
    end
end

--- Remove the previewed-buffer autocmds and stop the debounce timer.
---@return nil
function M.detach()
    pcall(api.nvim_del_augroup_by_name, AUGROUP)
    if timer and not timer:is_closing() then
        timer:stop()
    end
end

--- Release the debounce timer's libuv handle (VimLeavePre).
---@return nil
function M.dispose()
    M.detach()
    if timer and not timer:is_closing() then
        timer:close()
        timer = nil
    end
end

return M
