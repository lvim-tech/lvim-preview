-- lvim-preview.scroll: editor->browser sync scroll (markdown + asciidoc). A WinScrolled /
-- CursorMoved on a previewed buffer broadcasts a `scroll` frame carrying the top visible line and
-- the buffer's line count; the client jumps to the nearest block with a matching `data-source-line`
-- (markdown), or falls back to a proportional scroll (asciidoc, whose vendored converter does not
-- emit per-line anchors). One-way by design — the browser never moves the editor (safety rule);
-- two-way is a findings.md OPEN idea.
--
-- PER DOCUMENT: every previewed file owns its augroup and its last-line marker, so several
-- documents scroll-sync at once and each frame is addressed by that document's `url_path`.
--
---@module "lvim-preview.scroll"

local api = vim.api
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local server = require("lvim-preview.server")

local M = {}

---@type table<string, string>  doc path → its augroup name
local groups = {}
---@type table<string, integer>  doc path → last line broadcast, to suppress duplicate frames
local last_line = {}
---@type integer  augroup-name counter (a path is not a legal group name)
local seq = 0

--- Broadcast the current window's top line for `doc`, when its buffer is the focused one.
---@param doc LvimPreviewDoc
local function send_scroll(doc)
    local buf = doc.bufnr
    if not buf or api.nvim_get_current_buf() ~= buf then
        return
    end
    -- The top visible line drives the browser scroll (what the reader is looking at).
    local top = vim.fn.line("w0")
    if top == last_line[doc.file] then
        return
    end
    last_line[doc.file] = top
    server.broadcast({
        type = "scroll",
        path = doc.url_path,
        line = top,
        total = api.nvim_buf_line_count(buf),
    })
end

--- Install the sync-scroll autocmds for one document. No-op when sync_scroll is off or the kind is
--- html/svg (no source-line mapping to scroll to). Idempotent per document.
---@param doc LvimPreviewDoc
---@return nil
function M.attach(doc)
    M.detach(doc)
    if not config.sync_scroll or (doc.filetype ~= "markdown" and doc.filetype ~= "asciidoc") then
        return
    end
    seq = seq + 1
    local name = "LvimPreviewScroll_" .. seq
    groups[doc.file] = name
    local grp = api.nvim_create_augroup(name, { clear = true })
    api.nvim_create_autocmd({ "WinScrolled", "CursorMoved", "CursorMovedI" }, {
        group = grp,
        buffer = doc.bufnr,
        callback = function()
            send_scroll(doc)
        end,
    })
end

--- Remove ONE document's sync-scroll autocmds.
---@param doc LvimPreviewDoc
---@return nil
function M.detach(doc)
    local name = groups[doc.file]
    if name then
        pcall(api.nvim_del_augroup_by_name, name)
        groups[doc.file] = nil
    end
    last_line[doc.file] = nil
end

--- Detach every document (server stop / VimLeavePre).
---@return nil
function M.detach_all()
    for path, name in pairs(groups) do
        pcall(api.nvim_del_augroup_by_name, name)
        groups[path] = nil
        last_line[path] = nil
    end
end

return M
