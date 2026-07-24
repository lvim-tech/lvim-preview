-- lvim-preview.markdown: a self-contained CommonMark parser and HTML renderer, written in Lua and
-- run INSIDE Neovim. Nothing here is vendored and nothing is third-party: the whole markdown path is
-- our own code, which is why this plugin ships no markdown licence of any kind.
--
-- ── intended future ───────────────────────────────────────────────────────────────────────────
-- This tree lives under lvim-preview today but is written to be LIFTED OUT unchanged into a shared
-- home when the second consumer arrives, exactly like its `lvim-preview.org` sibling:
--   * lvim-preview  — this plugin: parse → tree → HTML → serve.
--   * lvim-render   — an in-buffer markdown/org decorator: parse → tree → extmarks. Needs the tree
--                     and the per-node line numbers; must never load the HTML renderer.
--   * a TOC / outline reader — parse → tree → the heading list with its source lines.
-- Therefore: the parsing core knows nothing about HTML, nothing about lvim-preview's template, and
-- nothing about `data-source-line`. It depends on no module outside this directory, uses no
-- `vim.api` / `vim.fn`, and every node carries the source line it came from. Moving these four files
-- to another plugin means changing the `require` prefix and nothing else.
--
-- ── what it implements ────────────────────────────────────────────────────────────────────────
-- CommonMark 0.31.2 in full, plus exactly the extensions the browser pipeline it replaces had
-- enabled: GFM pipe TABLES, GFM STRIKETHROUGH (`~~text~~` → `<s>`), raw HTML pass-through, and
-- optional GFM TASK LISTS. Deliberately NOT implemented, because they change what the author wrote:
-- smart typography (curly quotes, `--` → en dash) and bare-URL autolinking. Both were on in the
-- browser renderer; both are documented in the README as the two visible differences.
--
-- ── the document tree ─────────────────────────────────────────────────────────────────────────
-- Every node has `type`, `line` and `end_line` (absolute, 1-based, into the source text).
--
-- Block nodes:
--   document        children, refmap
--   paragraph       inlines
--   heading         level, inlines
--   code_block      content, info, language, fenced
--   html_block      content
--   thematic_break
--   block_quote     children
--   list            ordered, start, bullet, delimiter, tight, children(item[])
--   item            children, task("checked"|"unchecked")
--   table           head(MdTableRow), rows(MdTableRow[]), align[]
--
-- Inline nodes:
--   text            value
--   raw             value — raw HTML and pass-through character references, emitted verbatim
--   code            value (never re-scanned)
--   emph strong strike  children
--   link image      dest, title, children
--   softbreak linebreak
--
-- ── tolerance ─────────────────────────────────────────────────────────────────────────────────
-- Parsing never fails and never drops input. An unclosed fence runs to the end of its container, a
-- ragged table row keeps its cells, a malformed reference definition stays paragraph text, and any
-- inline construct that does not resolve stays the literal text the author typed.
--
---@module "lvim-preview.markdown"

local parser = require("lvim-preview.markdown.parser")
local html = require("lvim-preview.markdown.html")
local inline = require("lvim-preview.markdown.inline")

local M = {}

M.parser = parser
M.html = html
M.inline = inline

--- Parse markdown text into a document tree.
---@param text string|string[]  the document text, or its lines
---@param opts MdParseOptions?
---@return MdDocument
function M.parse(text, opts)
    return parser.parse(text, opts)
end

--- Render an already-parsed document to an HTML fragment.
---@param doc MdDocument
---@param opts MdHtmlOptions?
---@return string html
function M.render(doc, opts)
    return html.render(doc, opts)
end

--- Both option sets in one table, for the callers that do both steps at once.
---@class MdOptions : MdParseOptions, MdHtmlOptions

--- Parse and render in one step — what a previewer wants.
---@param text string|string[]
---@param opts MdOptions?
---@return string html
function M.to_html(text, opts)
    return html.render(parser.parse(text, opts), opts)
end

--- The plain text of a node's inline children (a heading's title, an image's alt text).
---@param nodes MdInlineNode[]
---@return string
function M.to_text(nodes)
    return inline.to_text(nodes)
end

return M
