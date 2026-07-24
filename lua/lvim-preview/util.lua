-- lvim-preview.util: pure helpers shared by the editor side and the fast HTTP callback. Kept
-- free of vim.api / editor state so `require`ing it from a libuv callback is safe — only string
-- work and vim.fs.normalize (pure).
--
---@module "lvim-preview.util"

local M = {}

-- File extension → preview render kind.
---@type table<string, string>
local EXT_KIND = {
    md = "markdown",
    markdown = "markdown",
    mkd = "markdown",
    adoc = "asciidoc",
    asciidoc = "asciidoc",
    asc = "asciidoc",
    svg = "svg",
    html = "html",
    htm = "html",
}

--- The preview render kind for a path from its extension, or nil when it is not previewable.
---@param path string
---@return string? kind  "markdown"|"asciidoc"|"svg"|"html"
function M.kind_for(path)
    local ext = path:match("%.([%w]+)$")
    return ext and EXT_KIND[ext:lower()] or nil
end

--- Whether `host` is a loopback address (127.0.0.0/8, ::1, localhost). Non-loopback binds
--- expose the preview to the LAN with no auth — health warns, start notes it.
---@param host string
---@return boolean
function M.is_loopback(host)
    return host == "localhost" or host == "::1" or host:match("^127%.") ~= nil
end

return M
