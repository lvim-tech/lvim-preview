-- lvim-preview.theme: the preview page's colour theme. Produces a block of CSS custom
-- properties (`--lp-*`) that style.css consumes for the page chrome and the markdown-body, AND —
-- for the "lvim" theme only — a block of `.hljs-*` rules that paint fenced code with the SAME
-- colours the editor gives each tree-sitter capture, so a code block in the browser matches the
-- editor's syntax highlighting. Both blocks live together in `state.theme_css` (read from the fast
-- HTTP path); building always happens on the main thread (setup / ColorScheme), where the palette
-- and the highlight groups are safe to read. Four modes:
--   * "lvim"  — generated from the LIVE editor: base `--lp-*` vars from the lvim-utils palette, the
--               per-level heading colours and every code-token colour from the tree-sitter highlight
--               GROUPS the editor actually paints (resolved with nvim_get_hl). Rebuilt and re-pushed
--               to every open tab on ColorScheme, so the browser's document AND code colours follow
--               the editor with no reload. This is why the "lvim" theme links NO vendored hljs
--               stylesheet (template.assets omits it) — the code CSS is generated here instead.
--   * "light" / "dark" — a fixed GitHub-ish palette; code is painted by the vendored github hljs CSS.
--   * "auto"  — ships BOTH and lets the browser's prefers-color-scheme pick.
--
-- Why resolve the editor's GROUPS rather than re-derive from the palette: `@keyword` may link
-- through several legacy groups before it lands on a colour, and a user override or a different
-- lvim-colorscheme theme changes that. nvim_get_hl(link=false) returns the effective colour the
-- editor shows — the single source of truth — so "same colours as the editor" is exact, not a guess.
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

--- `#rrggbb` for a 24-bit colour integer (as nvim_get_hl returns in `.fg`).
---@param n integer
---@return string
local function hex(n)
    return ("#%06x"):format(n)
end

--- The effective FOREGROUND colour the editor paints for a highlight group, as `#rrggbb`, or nil
--- when the group is undefined or has no fg. `link = false` follows the whole link chain and returns
--- the resolved attributes, so a group defined only as a link to a legacy group (`@string` → String)
--- still yields its final colour — the exact colour on screen.
---@param group string
---@return string?
local function resolve(group)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
    if ok and hl and hl.fg then
        return hex(hl.fg)
    end
    return nil
end

-- hljs code-token classes → the CSS selectors that class covers + a palette fallback field. The
-- COLOUR of each is not here — it is the tree-sitter group `config.theme_lvim.code[<key>]` resolves
-- to, pulled live; `fb` (a lvim-utils.colors field) is used only when that group is undefined (e.g.
-- no colorscheme loaded). `style` adds a weight/slant highlight.js's own github theme also applies.
-- highlight.js is coarser than tree-sitter, so several classes fold onto the nearest capture — the
-- honest mapping is exactly what these keys say (built_in → @function.builtin, literal →
-- @constant.builtin, attr/selector → @property/@variable, meta → @keyword.directive, …).
---@class LvimPreviewCodeSpec
---@field sel   string[]  the hljs selectors this token class paints
---@field fb    string    lvim-utils.colors field used when the mapped group is undefined
---@field style string?   "bold" | "italic"
---@type table<string, LvimPreviewCodeSpec>
local CODE_SPEC = {
    keyword = {
        sel = {
            ".hljs-keyword",
            ".hljs-doctag",
            ".hljs-meta .hljs-keyword",
            ".hljs-template-tag",
            ".hljs-template-variable",
        },
        fb = "purple",
    },
    func = { sel = { ".hljs-title", ".hljs-title.function_", ".hljs-function" }, fb = "blue" },
    builtin = { sel = { ".hljs-built_in" }, fb = "orange" },
    type = { sel = { ".hljs-type", ".hljs-title.class_", ".hljs-title.class_.inherited__" }, fb = "yellow" },
    variable = { sel = { ".hljs-variable" }, fb = "red" },
    variable_builtin = { sel = { ".hljs-variable.language_" }, fb = "blue" },
    property = { sel = { ".hljs-attr", ".hljs-attribute", ".hljs-property" }, fb = "teal" },
    string = { sel = { ".hljs-string", ".hljs-meta .hljs-string", ".hljs-code" }, fb = "green" },
    regexp = { sel = { ".hljs-regexp" }, fb = "fg_light" },
    number = { sel = { ".hljs-number" }, fb = "orange" },
    literal = { sel = { ".hljs-literal" }, fb = "orange" },
    symbol = { sel = { ".hljs-symbol" }, fb = "orange" },
    comment = { sel = { ".hljs-comment", ".hljs-quote", ".hljs-formula" }, fb = "comment" },
    operator = { sel = { ".hljs-operator" }, fb = "cyan_dark" },
    punctuation = { sel = { ".hljs-punctuation" }, fb = "fg_soft_dark" },
    meta = { sel = { ".hljs-meta" }, fb = "purple_dark" },
    tag = { sel = { ".hljs-name", ".hljs-selector-tag", ".hljs-selector-pseudo", ".hljs-tag" }, fb = "green_dark" },
    selector = { sel = { ".hljs-selector-attr", ".hljs-selector-class", ".hljs-selector-id" }, fb = "blue" },
    section = { sel = { ".hljs-section" }, fb = "blue", style = "bold" },
    bullet = { sel = { ".hljs-bullet" }, fb = "yellow" },
    addition = { sel = { ".hljs-addition" }, fb = "green" },
    deletion = { sel = { ".hljs-deletion" }, fb = "red" },
}

-- Emission order: less-specific selectors first so a more-specific override (e.g. `.hljs-title`
-- before `.hljs-title.function_`, `.hljs-variable` before `.hljs-variable.language_`) wins by
-- source order as well as specificity. Stable, so the cached CSS string does not churn.
local CODE_ORDER = {
    "comment",
    "keyword",
    "func",
    "type",
    "builtin",
    "variable",
    "variable_builtin",
    "property",
    "selector",
    "string",
    "regexp",
    "number",
    "literal",
    "symbol",
    "operator",
    "punctuation",
    "meta",
    "tag",
    "section",
    "bullet",
    "addition",
    "deletion",
}

--- Build the base `--lp-*` var map from the live lvim-utils palette, honouring the
--- `config.theme_lvim` overrides. Falls back to DARK when the palette is unavailable, so the page is
--- always readable.
---@return table<string, string>
local function lvim_vars()
    local ok, c = pcall(require, "lvim-utils.colors")
    if not ok or type(c.blend) ~= "function" then
        return DARK
    end
    local tl = config.theme_lvim or {}
    -- Is the active theme light or dark? Decide from the background's luminance so KaTeX /
    -- hljs / mermaid pick the matching sub-theme.
    local bg = c.bg or "#1a1f21"
    local r = tonumber(bg:sub(2, 3), 16) or 0
    local g = tonumber(bg:sub(4, 5), 16) or 0
    local b = tonumber(bg:sub(6, 7), 16) or 0
    local is_light = (0.299 * r + 0.587 * g + 0.114 * b) > 140

    local vars = {
        ["--lp-bg"] = c.bg,
        ["--lp-bg-soft"] = c.bg_dark or c.bg,
        ["--lp-fg"] = c.fg,
        ["--lp-fg-muted"] = c.comment or c.fg_dark or c.fg,
        ["--lp-border"] = tl.table_border or c.bg_highlight or c.bg_dark,
        -- Single heading colour kept as the FALLBACK for the per-level vars below (and for the fixed
        -- themes' selectors): a level with no rainbow group resolves through it, never to nothing.
        ["--lp-heading"] = c.fg_light or c.fg,
        ["--lp-link"] = tl.link or c.blue,
        ["--lp-code-bg"] = tl.code_bg or c.bg_dark or c.bg,
        ["--lp-code-fg"] = tl.code_fg or c.fg,
        ["--lp-quote-fg"] = tl.quote_fg or c.comment or c.fg_dark,
        ["--lp-quote-border"] = tl.quote_border or c.purple or c.blue,
        ["--lp-accent"] = c.blue,
        ["--lp-table-border"] = tl.table_border or c.bg_highlight or c.bg_dark,
        ["--lp-table-header-bg"] = tl.table_header_bg or c.blend(c.blue, c.bg, 0.12),
        ["--lp-table-alt"] = tl.table_alt_bg or c.blend(c.blue, c.bg, 0.06),
        ["--lp-selection"] = tl.selection or c.blend(c.blue, c.bg, 0.3),
        ["--lp-hljs"] = is_light and "light" or "dark",
    }

    -- Per-level heading colours. Pinned override wins; else the editor's markdown heading group for
    -- that level (the palette rainbow — the SAME colour the editor paints an h-N heading); else a
    -- step through the palette accents so the six levels still read as a hierarchy standalone.
    local groups = tl.heading_groups or {}
    local pins = tl.headings or {}
    local cycle = { c.red, c.orange, c.yellow, c.green, c.blue, c.purple }
    for i = 1, 6 do
        local col = pins[i] or (groups[i] and resolve(groups[i])) or cycle[i] or c.fg_light or c.fg
        vars["--lp-h" .. i] = col
    end
    return vars
end

--- The `.hljs-*` code-colour CSS for the "lvim" theme, resolved from the editor's tree-sitter
--- groups (config.theme_lvim.code), with a palette fallback per token class. Emitted alongside the
--- `:root` block so a ColorScheme re-push carries the new code colours too; the fixed light/dark
--- themes use the vendored github hljs stylesheet instead and never call this.
---@return string css
local function hljs_css()
    local ok, c = pcall(require, "lvim-utils.colors")
    if not ok then
        return ""
    end
    local map = (config.theme_lvim or {}).code or {}
    local rules = {
        -- Base surface: text colour + structural layout come from --lp-code-* / style.css; the
        -- background stays transparent because the enclosing <pre> already carries --lp-code-bg.
        ".markdown-body .hljs { color: var(--lp-code-fg); background: transparent; }",
    }
    for _, key in ipairs(CODE_ORDER) do
        local spec = CODE_SPEC[key]
        local group = map[key]
        local col = (group and resolve(group)) or c[spec.fb]
        if col then
            -- Scope under .markdown-body so a generated rule beats the base github-markdown-css
            -- specificity without needing !important, exactly as the vendored hljs theme would.
            local sels = {}
            for _, s in ipairs(spec.sel) do
                sels[#sels + 1] = ".markdown-body " .. s
            end
            local decl = "color: " .. col .. ";"
            if spec.style == "bold" then
                decl = decl .. " font-weight: 700;"
            elseif spec.style == "italic" then
                decl = decl .. " font-style: italic;"
            end
            rules[#rules + 1] = ("%s { %s }"):format(table.concat(sels, ", "), decl)
        end
    end
    -- Emphasis / strong carry no colour of their own in either theme — only a slant/weight.
    rules[#rules + 1] = ".markdown-body .hljs-emphasis { font-style: italic; }"
    rules[#rules + 1] = ".markdown-body .hljs-strong { font-weight: 700; }"
    return table.concat(rules, "\n")
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
    -- "lvim" (default) — from the live palette + the editor's tree-sitter code colours.
    return block(lvim_vars(), ":root") .. "\n" .. hljs_css()
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
