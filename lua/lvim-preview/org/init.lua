-- lvim-preview.org: a self-contained org-mode parser and HTML renderer, written in Lua and run
-- INSIDE Neovim. Nothing here is vendored and nothing is third-party: the whole org path is our
-- own code, which is why this plugin ships no org licence of any kind.
--
-- ── intended future ───────────────────────────────────────────────────────────────────────────
-- This tree lives under lvim-preview today but is written to be LIFTED OUT unchanged into a
-- shared home when the second consumer arrives. Three consumers are planned:
--   * lvim-preview  — this plugin: parse → tree → HTML → serve.
--   * lvim-render   — an in-buffer markdown/org decorator: parse → tree → extmarks. Needs the
--                     tree and the per-node line numbers; must never load the HTML renderer.
--   * lvim-org      — editing / agenda: parse → tree → headline metadata (TODO state, priority,
--                     tags, properties, timestamps).
-- Therefore: the parsing core knows nothing about HTML, nothing about lvim-preview's template,
-- and nothing about `data-source-line`. It depends on no module outside this directory, uses no
-- `vim.api` / `vim.fn`, and every node carries the source line it came from. Moving these four
-- files to another plugin means changing the `require` prefix and nothing else.
--
-- The API is also deliberately shaped around the DOCUMENT TREE rather than around how the tree
-- was produced. There is no org treesitter grammar in the parser registry this ecosystem uses; if
-- one ever arrives, it can back `M.parse` without any caller noticing.
--
-- ── the document tree ─────────────────────────────────────────────────────────────────────────
-- Every node has `type`, `line` and `end_line` (absolute, 1-based, into the source text).
--
-- Block nodes:
--   document             children, keywords, footnotes, footnote_order
--   headline             level, todo, todo_done, priority, tags[], title(inline[]), properties,
--                        children
--   paragraph            children(inline[])
--   list                 ordered, items(list_item[])
--   list_item            bullet, counter, checkbox("unchecked"|"checked"|"partial"),
--                        term(inline[]) for a description item, children
--   table                rows(OrgTableRow[]), has_header, header_rows
--   block                name, params, language(src), value(verbatim bodies) | children(nested)
--   fixed_width          value
--   horizontal_rule
--   keyword              key(lowercased), value
--   comment              value
--   drawer               name, children
--   property_drawer      properties(map), order(string[])
--   latex_environment    value
--   footnote_definition  label, children
--   unknown              value — a line no construct claimed, kept verbatim (see "tolerance")
--
-- Inline nodes:
--   text                 value
--   bold italic underline strike superscript subscript   children
--   code verbatim        value (never re-scanned)
--   link                 path, protocol, description(inline[]?), image, raw
--   latex_fragment       value (delimiters INCLUDED), display
--   timestamp            value, active
--   footnote_reference   label, inline(inline[]?)
--   target               value
--   line_break
--
-- ── tolerance ─────────────────────────────────────────────────────────────────────────────────
-- Parsing never fails and never drops input. Unterminated blocks and drawers close at their
-- section boundary, unknown block names and keywords are preserved, ragged tables keep their
-- cells, and any inline construct that does not resolve stays the literal text the author typed.
--
---@module "lvim-preview.org"

local parser = require("lvim-preview.org.parser")
local html = require("lvim-preview.org.html")
local inline = require("lvim-preview.org.inline")

local M = {}

M.parser = parser
M.html = html
M.inline = inline

--- Parse org text into a document tree.
---@param text string|string[]   the document text, or its lines
---@param opts OrgParseOptions?  { todo_keywords }
---@return OrgDocument
function M.parse(text, opts)
    return parser.parse(text, opts)
end

--- Render an already-parsed document to an HTML fragment.
---@param doc OrgDocument
---@param opts OrgHtmlOptions?
---@return string html
function M.render(doc, opts)
    return html.render(doc, opts)
end

--- Both option sets in one table, for the callers that do both steps at once.
---@class OrgOptions : OrgParseOptions, OrgHtmlOptions

--- Parse and render in one step — what a previewer wants.
---@param text string|string[]
---@param opts OrgOptions?
---@return string html
function M.to_html(text, opts)
    return html.render(parser.parse(text, opts), opts)
end

--- The plain text of a node's inline children (a heading's title, a link's description).
---@param nodes table[]
---@return string
function M.to_text(nodes)
    return inline.to_text(nodes)
end

return M
