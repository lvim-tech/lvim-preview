-- lvim-preview.scroll: editor->browser sync scroll (markdown + asciidoc). A WinScrolled /
-- CursorMoved on the previewed buffer broadcasts a `scroll` frame carrying the top visible
-- line and the buffer's line count; the client jumps to the nearest block with a matching
-- `data-source-line` (markdown), or falls back to a proportional scroll (asciidoc, whose
-- vendored converter does not emit per-line anchors). One-way by design — the browser never
-- moves the editor (safety rule); two-way is a findings.md OPEN idea.
--
---@module "lvim-preview.scroll"

local api = vim.api
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local server = require("lvim-preview.server")

local M = {}

local AUGROUP = "LvimPreviewScroll"

---@type integer  last line broadcast, to suppress duplicate frames
local last_line = -1

--- Broadcast the current window's top line for the previewed buffer.
local function send_scroll()
    local buf = state.bufnr
    if not buf or api.nvim_get_current_buf() ~= buf then
        return
    end
    -- The top visible line drives the browser scroll (what the reader is looking at).
    local top = vim.fn.line("w0")
    if top == last_line then
        return
    end
    last_line = top
    server.broadcast({
        type = "scroll",
        path = state.url_path,
        line = top,
        total = api.nvim_buf_line_count(buf),
    })
end

--- Install the sync-scroll autocmds for the previewed buffer. No-op when sync_scroll is off or
--- the kind is html/svg (no source-line mapping to scroll to).
---@param bufnr integer
---@param filetype string
---@return nil
function M.attach(bufnr, filetype)
    M.detach()
    if not config.sync_scroll or (filetype ~= "markdown" and filetype ~= "asciidoc") then
        return
    end
    local grp = api.nvim_create_augroup(AUGROUP, { clear = true })
    api.nvim_create_autocmd({ "WinScrolled", "CursorMoved", "CursorMovedI" }, {
        group = grp,
        buffer = bufnr,
        callback = send_scroll,
    })
end

--- Remove the sync-scroll autocmds.
---@return nil
function M.detach()
    pcall(api.nvim_del_augroup_by_name, AUGROUP)
    last_line = -1
end

return M
