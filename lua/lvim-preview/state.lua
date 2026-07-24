-- lvim-preview.state: the SESSION-scoped runtime state (memory only, never persisted — per
-- the set's config convention, state.lua holds runtime handles while config.lua holds knobs).
-- One server per Neovim instance, so this is a single table, not a registry. The content
-- CACHE is the seam that lets the HTTP path (a libuv "fast" callback where vim.api is illegal)
-- serve the previewed buffer's UNSAVED text on first load: the watch/init code refreshes it on
-- the main thread, the http handler only reads the plain string.
--
---@module "lvim-preview.state"

---@class LvimPreviewState
---@field running   boolean            Whether the server is currently listening.
---@field host      string             The address actually bound.
---@field port      integer            The port actually bound (may differ from config when auto_port scanned).
---@field root      string             Absolute, normalised servable root.
---@field file      string?            Absolute path of the previewed document.
---@field bufnr     integer?           Buffer of the previewed document (when loaded).
---@field filetype  string?            Resolved preview kind ("markdown"|"html"|"asciidoc"|"svg").
---@field url_path  string             URL path of the previewed file relative to the root ("/README.md").
---@field content   string?            Cached text of the previewed buffer (unsaved edits included).
---@field theme_css  string             Cached preview-theme CSS (rebuilt on the main thread; read in the fast HTTP path).
---@field listener  uv.uv_tcp_t?       The bound TCP listener handle.
---@field clients   table[]            Connected client contexts (see server/init.lua ClientCtx).
local state = {
    running = false,
    host = "127.0.0.1",
    port = 5500,
    root = "",
    file = nil,
    bufnr = nil,
    filetype = nil,
    url_path = "/",
    content = nil,
    theme_css = "",
    listener = nil,
    clients = {},
}

return state
