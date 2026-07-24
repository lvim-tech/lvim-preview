-- lvim-preview.theme: the preview page's colour theme. Produces a block of CSS custom
-- properties (`--lp-*`) that style.css consumes for the page chrome and the markdown-body, so
-- the served page tracks the editor's look. Four modes:
--   * "lvim"  — generated from the LIVE lvim-utils palette; rebuilt and re-pushed to every open
--               tab on ColorScheme so the browser follows the editor theme without a reload.
--   * "light" / "dark" — a fixed GitHub-ish palette.
--   * "auto"  — ships BOTH and lets the browser's prefers-color-scheme pick.
-- The built CSS is cached in state.theme_css (read from the fast HTTP path); building always
-- happens on the main thread (setup / ColorScheme), where the palette is safe to read.
--
---@module "lvim-preview.theme"

local config = require("lvim-preview.config")
local state = require("lvim-preview.state")

local M = {}

--- One `:root { … }` (or media-scoped) block from a name→value var map.
---@param vars table<string, string>
---@param selector string  e.g. ":root" or ':root[data-lp-scheme="dark"]'
---@return string
local function block(vars, selector)
    local lines = {}
    -- deterministic order for a stable cache string
    local keys = {}
    for k in pairs(vars) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        lines[#lines + 1] = ("  %s: %s;"):format(k, vars[k])
    end
    return ("%s {\n%s\n}"):format(selector, table.concat(lines, "\n"))
end

-- A fixed light palette (GitHub-ish) for theme = "light" / "auto" light half.
local LIGHT = {
    ["--lp-bg"] = "#ffffff",
    ["--lp-bg-soft"] = "#f6f8fa",
    ["--lp-fg"] = "#1f2328",
    ["--lp-fg-muted"] = "#59636e",
    ["--lp-border"] = "#d1d9e0",
    ["--lp-heading"] = "#1f2328",
    ["--lp-link"] = "#0969da",
    ["--lp-code-bg"] = "#f6f8fa",
    ["--lp-code-fg"] = "#1f2328",
    ["--lp-quote-fg"] = "#59636e",
    ["--lp-quote-border"] = "#d1d9e0",
    ["--lp-accent"] = "#0969da",
    ["--lp-table-border"] = "#d1d9e0",
    ["--lp-table-alt"] = "#f6f8fa",
    ["--lp-selection"] = "#b6e3ff",
    ["--lp-hljs"] = "light",
}

-- A fixed dark palette (GitHub-ish) for theme = "dark" / "auto" dark half.
local DARK = {
    ["--lp-bg"] = "#0d1117",
    ["--lp-bg-soft"] = "#151b23",
    ["--lp-fg"] = "#e6edf3",
    ["--lp-fg-muted"] = "#9198a1",
    ["--lp-border"] = "#3d444d",
    ["--lp-heading"] = "#e6edf3",
    ["--lp-link"] = "#4493f8",
    ["--lp-code-bg"] = "#151b23",
    ["--lp-code-fg"] = "#e6edf3",
    ["--lp-quote-fg"] = "#9198a1",
    ["--lp-quote-border"] = "#3d444d",
    ["--lp-accent"] = "#4493f8",
    ["--lp-table-border"] = "#3d444d",
    ["--lp-table-alt"] = "#151b23",
    ["--lp-selection"] = "#264f78",
    ["--lp-hljs"] = "dark",
}

--- Build the var map from the live lvim-utils palette. Falls back to DARK when the palette is
--- unavailable, so the page is always readable.
---@return table<string, string>
local function lvim_vars()
    local ok, c = pcall(require, "lvim-utils.colors")
    if not ok or type(c.blend) ~= "function" then
        return DARK
    end
    -- Is the active theme light or dark? Decide from the background's luminance so KaTeX /
    -- hljs pick the matching sub-theme.
    local bg = c.bg or "#1a1f21"
    local r = tonumber(bg:sub(2, 3), 16) or 0
    local g = tonumber(bg:sub(4, 5), 16) or 0
    local b = tonumber(bg:sub(6, 7), 16) or 0
    local is_light = (0.299 * r + 0.587 * g + 0.114 * b) > 140
    return {
        ["--lp-bg"] = c.bg,
        ["--lp-bg-soft"] = c.bg_dark or c.bg,
        ["--lp-fg"] = c.fg,
        ["--lp-fg-muted"] = c.comment or c.fg_dark or c.fg,
        ["--lp-border"] = c.bg_highlight or c.bg_dark,
        ["--lp-heading"] = c.fg_light or c.fg,
        ["--lp-link"] = c.blue,
        ["--lp-code-bg"] = c.bg_dark or c.bg,
        ["--lp-code-fg"] = c.fg,
        ["--lp-quote-fg"] = c.comment or c.fg_dark,
        ["--lp-quote-border"] = c.blue,
        ["--lp-accent"] = c.blue,
        ["--lp-table-border"] = c.bg_highlight or c.bg_dark,
        ["--lp-table-alt"] = c.blend(c.blue, c.bg, 0.06),
        ["--lp-selection"] = c.blend(c.blue, c.bg, 0.3),
        ["--lp-hljs"] = is_light and "light" or "dark",
    }
end

--- Assemble the theme CSS string for the current config.theme.
---@return string css
function M.build()
    local theme = config.theme
    if theme == "light" then
        return block(LIGHT, ":root")
    elseif theme == "dark" then
        return block(DARK, ":root")
    elseif theme == "auto" then
        -- Default to light, swap to dark under a dark OS preference.
        return block(LIGHT, ":root") .. "\n@media (prefers-color-scheme: dark) {\n" .. block(DARK, ":root") .. "\n}"
    end
    -- "lvim" (default) — from the live palette.
    return block(lvim_vars(), ":root")
end

--- Rebuild the cached theme CSS (main thread). Returns the CSS.
---@return string css
function M.refresh()
    state.theme_css = M.build()
    return state.theme_css
end

--- Rebuild AND push `{ type = "theme", css }` to every open tab (called on ColorScheme). No-op
--- when the server is not running.
---@return nil
function M.refresh_and_push()
    local css = M.refresh()
    if state.running then
        require("lvim-preview.server").broadcast({ type = "theme", css = css })
    end
end

return M
