-- lvim-preview.util: pure helpers shared by the editor side and the fast HTTP callback. Kept
-- free of vim.api / editor state so `require`ing it from a libuv callback is safe — only string
-- work, `vim.fs.normalize` / `vim.islist` (pure) and the plain config table.
--
-- The extension→kind map here is the SINGLE source of truth for "what can this plugin render":
-- one entry per extension, mapping to the render kind the template + client.js branch on.
-- `config.filetypes` is the user's gate ON TOP of it — a kind the user removed is not
-- previewable at all, which is what the option has always claimed and now actually does (the
-- picker, `preview_file` and the HTTP router all funnel through `kind_for`, so they can never
-- disagree about what is previewable).
--
---@module "lvim-preview.util"

local config = require("lvim-preview.config")

local M = {}

-- File extension → preview render kind. Adding a format means: one row here, a branch in
-- template.M.shell, a branch in static/client.js, and the kind in config.filetypes' default.
---@type table<string, string>
local EXT_KIND = {
    md = "markdown",
    markdown = "markdown",
    mkd = "markdown",
    org = "org",
}

M.EXT_KIND = EXT_KIND

--- Whether `kind` is enabled by `config.filetypes`. A missing / malformed list means "no gate"
--- rather than "nothing previewable" — a typo in setup() must not silently disable the plugin.
---@param kind string
---@return boolean
local function enabled(kind)
    local list = config.filetypes
    if type(list) ~= "table" or #list == 0 then
        return true
    end
    for _, ft in ipairs(list) do
        if ft == kind then
            return true
        end
    end
    return false
end

--- The preview render kind for a path from its extension, or nil when it is not previewable —
--- either because nothing here renders that extension, or because `config.filetypes` excludes
--- the kind it maps to.
---@param path string
---@return string? kind  "markdown"|"org"
function M.kind_for(path)
    local ext = path:match("%.([%w]+)$")
    if not ext then
        return nil
    end
    local kind = EXT_KIND[ext:lower()]
    if not kind or not enabled(kind) then
        return nil
    end
    return kind
end

--- The set of file EXTENSIONS currently previewable (EXT_KIND filtered by config.filetypes) —
--- what the picker scans for. Derived, never a second hand-kept list.
---@return table<string, boolean>
function M.enabled_exts()
    local set = {}
    for ext, kind in pairs(EXT_KIND) do
        if enabled(kind) then
            set[ext] = true
        end
    end
    return set
end

--- Deep-merge `opts` into `target` IN PLACE with the ecosystem's merge semantics: dict tables
--- merge recursively, LISTS and scalars are replaced wholesale. This mirrors
--- `lvim-utils.utils.merge` exactly and exists only as the fallback for a runtime without
--- lvim-utils — `vim.tbl_deep_extend("force", …)` is NOT equivalent (it index-merges arrays, so
--- `filetypes = { "markdown" }` over a 5-element default would leave the last 4 defaults behind).
---@param target table
---@param opts table?
---@return table target
function M.merge(target, opts)
    for k, v in pairs(opts or {}) do
        if type(v) == "table" and type(target[k]) == "table" and not vim.islist(v) then
            M.merge(target[k], v)
        else
            target[k] = v
        end
    end
    return target
end

--- Whether `host` is a loopback address (127.0.0.0/8, ::1, localhost). Non-loopback binds
--- expose the preview to the LAN with no auth — health warns, start notes it.
---@param host string
---@return boolean
function M.is_loopback(host)
    return host == "localhost" or host == "::1" or host:match("^127%.") ~= nil
end

return M
