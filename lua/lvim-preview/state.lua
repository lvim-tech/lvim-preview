-- lvim-preview.state: the SESSION-scoped runtime state (memory only, never persisted — per
-- the set's config convention, state.lua holds runtime handles while config.lua holds knobs).
--
-- ONE server per Neovim instance, but MANY previewed documents. The server-level fields below
-- (listener / clients / host / port / root) stay single, while every previewed file gets its own
-- entry in the `docs` registry — that is what lets several browser tabs each track a DIFFERENT
-- file live: previewing a second document no longer replaces the first, it joins it. Every frame
-- carries its document's `url_path` and the client only applies the ones addressed to the page it
-- is showing, so a single broadcast serves every tab correctly.
--
-- The per-document content CACHE is the seam that lets the HTTP path (a libuv "fast" callback
-- where vim.api is illegal) serve a previewed buffer's UNSAVED text on first load: the watch code
-- refreshes it on the main thread, the http handler only reads the plain string.
--
---@module "lvim-preview.state"

---@class LvimPreviewDoc
---@field file      string   Absolute, normalised path of the document.
---@field bufnr     integer? Buffer of the document (when loaded).
---@field filetype  string   Resolved preview kind ("markdown"|"html"|"asciidoc"|"svg").
---@field url_path  string   URL path of the file relative to the root ("/README.md").
---@field content   string?  Cached text of the buffer (unsaved edits included).

---@class LvimPreviewState
---@field running   boolean            Whether the server is currently listening.
---@field host      string             The address actually bound.
---@field port      integer            The port actually bound (may differ from config when auto_port scanned).
---@field root      string             Absolute, normalised servable root.
---@field docs      table<string, LvimPreviewDoc>  Previewed documents, keyed by absolute path.
---@field theme_css string             Cached preview-theme CSS (rebuilt on the main thread; read in the fast HTTP path).
---@field listener  uv.uv_tcp_t?       The bound TCP listener handle.
---@field clients   table[]            Connected client contexts (see server/init.lua ClientCtx).
local state = {
    running = false,
    host = "127.0.0.1",
    port = 5500,
    root = "",
    docs = {},
    theme_css = "",
    listener = nil,
    clients = {},
}

--- The document previewed from `abs` (an already-normalised absolute path), or nil.
---@param abs string?
---@return LvimPreviewDoc?
function state.doc(abs)
    if not abs then
        return nil
    end
    return state.docs[abs]
end

--- The document whose buffer is `bufnr`, or nil — the watch / scroll hooks fire with a buffer
--- handle rather than a path.
---@param bufnr integer?
---@return LvimPreviewDoc?
function state.doc_for_buf(bufnr)
    if not bufnr then
        return nil
    end
    for _, doc in pairs(state.docs) do
        if doc.bufnr == bufnr then
            return doc
        end
    end
    return nil
end

--- The document served at `url_path`, or nil. FAST-PATH SAFE: a plain string comparison against
--- the url_path stored at registration — no vim.fs / vim.fn call — because this also runs inside
--- the libuv HTTP callback, where the Neovim API is off limits.
---@param url_path string?
---@return LvimPreviewDoc?
function state.doc_for_url(url_path)
    if not url_path then
        return nil
    end
    for _, doc in pairs(state.docs) do
        if doc.url_path == url_path then
            return doc
        end
    end
    return nil
end

--- Number of documents currently previewed.
---@return integer
function state.count()
    local n = 0
    for _ in pairs(state.docs) do
        n = n + 1
    end
    return n
end

--- Every previewed document, ordered by url_path — a stable listing for status / health / picker.
---@return LvimPreviewDoc[]
function state.list()
    local out = {}
    for _, doc in pairs(state.docs) do
        out[#out + 1] = doc
    end
    table.sort(out, function(a, b)
        return a.url_path < b.url_path
    end)
    return out
end

return state
