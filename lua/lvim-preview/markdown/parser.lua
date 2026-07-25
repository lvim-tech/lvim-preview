-- lvim-preview.markdown.parser: the BLOCK-level CommonMark parser — markdown text in, a document
-- TREE out. The inline/span level is a different shape and lives in `lvim-preview.markdown.inline`.
--
-- ── why this is not a line-oriented state machine ─────────────────────────────────────────────
-- The org parser next door IS one, because org's block level is line-regular: how a line starts
-- decides what it is. Markdown is not. `> - a` opens two containers on one line; a paragraph
-- continues across a line that would otherwise start a container ("lazy continuation"); an item's
-- content column depends on how many spaces followed its bullet; a tab counts to the next multiple
-- of four, not as one column. So this follows the ALGORITHM the CommonMark spec specifies:
--
--   1. for each line, walk the still-OPEN containers from the document down and ask each whether
--      the line continues it (consuming its prefix — `> `, an item's indent — as it goes);
--   2. then look for NEW block starts at whatever offset is left, closing what did not match;
--   3. then hand the remainder to the deepest open block that accepts lines.
--
-- Leaf blocks only accumulate TEXT in phase one. Inline parsing is a second pass, and it has to be:
-- a `[foo]` may refer to a `[foo]: /url` that appears further down the document, so no inline can
-- be resolved until every link reference definition has been collected.
--
-- TOLERANCE IS A DESIGN RULE, as in the org parser: no input is rejected and nothing is dropped. An
-- unclosed fence runs to the end of its container, a ragged table row keeps its cells, a malformed
-- reference definition stays paragraph text, and any inline construct that does not resolve stays
-- the literal text the author typed.
--
-- Every node carries `line` / `end_line`, the ABSOLUTE 1-based source lines it came from. That is
-- what the HTML renderer turns into `data-source-line` anchors, which is what makes editor→browser
-- scroll sync exact rather than proportional.
--
-- Pure Lua, pure string work: no vim.api / vim.fn, so it is callable from the libuv HTTP callback
-- and portable out of this plugin (see `lvim-preview.markdown`).
--
---@module "lvim-preview.markdown.parser"

local inline = require("lvim-preview.markdown.inline")
local polish = require("lvim-preview.markdown.polish")

local M = {}

local CODE_INDENT = 4

---@class MdParseOptions : MdPolishOptions
---@field tables     boolean?  parse GFM pipe tables (default true)
---@field strike     boolean?  parse `~~text~~` deletions (default true)
---@field task_lists boolean?  turn `- [ ]` into a checkbox item (default false)
---@field footnotes  boolean?  parse `[^label]:` definitions and `[^label]` references (default false
---                            here; the facade defaults it on)
---@field emoji      boolean?  turn `:shortcode:` into its emoji glyph (default false here; on in the
---                            facade)

---@class MdTableRow
---@field cells MdInlineNode[][]  per cell, its inline nodes
---@field line  integer

--- ONE node shape for the whole tree, with every construct's fields optional. Deliberately not a
--- union of per-type classes: consumers walk the tree by `type` and read the fields that type
--- documents (see `lvim-preview.markdown` for the type→field table), and a single class keeps that
--- walk simple in both Lua and the language server.
---@class MdNode
---@field type      string     node type (see `lvim-preview.markdown` for the full list)
---@field line      integer    1-based first source line of the node
---@field end_line  integer    1-based last source line of the node
---@field children  MdNode[]   block children
---@field inlines   MdInlineNode[]?  paragraph / heading / table cell: its inline nodes
---@field content   string?    internal: raw text accumulated during phase one
---@field level     integer?   heading: its depth
---@field info      string?    code_block: the full info string
---@field language  string?    code_block: the first word of the info string
---@field fenced    boolean?   code_block: whether it was written as a fence
---@field ordered   boolean?   list: whether it is numbered
---@field start     integer?   list: an ordered list's first number
---@field tight     boolean?   list: whether its items render without paragraphs
---@field delimiter string?    list: `.` or `)` for an ordered list
---@field bullet    string?    list: `-`, `+` or `*` for a bullet list
---@field task      string?    item: "checked" | "unchecked" for a GFM task-list item
---@field fn_label   string?    footnote_def: its label (as written, before lower-casing)
---@field fn_indent  integer?   internal: a footnote definition's continuation-line indent
---@field rows      MdTableRow[]?  table: its body rows
---@field head      MdTableRow?    table: its header row
---@field align     string[]?  table: per column, "left" | "right" | "center" | ""
---@field open      boolean?   internal: still accepting lines
---@field parent    MdNode?    internal: owner during phase one
---@field fence_length integer?  internal: a fence's marker length, for matching its closer
---@field fence_char   string?   internal: a fence's marker character
---@field fence_offset integer?  internal: a fence's own indent, stripped from every content line
---@field html_block_type integer?  internal: which of the spec's seven HTML block types this is
---@field list_data      table?    internal: a list / item's marker shape and content indent
---@field last_line_blank boolean? internal: whether the last line taken was blank (list tightness)
---@field blank_checked   boolean? internal: guard for the recursive tightness test

---@class MdDocument : MdNode
---@field refmap table<string, { dest: string, title: string? }>  link reference definitions
---@field footnotes table<string, MdNode>  footnote definitions by lower-cased label
---@field footnote_order string[]           labels in first-definition order

-- Tag names that open a type-6 HTML block (the "known block element" list from the spec).
local BLOCK_TAGS = {}
for tag in
    ([[address article aside base basefont blockquote body caption center col colgroup dd details
       dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6
       head header hr html iframe legend li link main menu menuitem nav noframes ol optgroup option
       p param search section summary table tbody td tfoot th thead title tr track ul]]):gmatch("%S+")
do
    BLOCK_TAGS[tag] = true
end

-- Blocks that accumulate raw lines in phase one.
local ACCEPTS_LINES = { paragraph = true, heading = true, code_block = true, html_block = true }

--- Trim ASCII whitespace off both ends.
---@param s string
---@return string
local function trim(s)
    return (s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
end

--- Drop every trailing line that holds nothing but spaces, and the final newline with them.
---@param s string
---@return string
local function strip_trailing_blank_lines(s)
    while true do
        local stripped = s:gsub("\n[ ]*$", "")
        if stripped == s then
            return s
        end
        s = stripped
    end
end

--- Split text into lines, tolerating CRLF, a missing trailing newline and NUL bytes.
---
--- A stray `\r` would leak into headings, code blocks and table cells and break every pattern
--- anchored with `$`, so it is stripped here once rather than guarded against in twenty patterns.
--- NUL is replaced with U+FFFD, which the spec requires and which also keeps a binary file that was
--- mistakenly opened as markdown from producing an unterminated C string in the served page.
---@param text string
---@return string[]
local function split_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""):gsub("%z", "\239\191\189"))
    end
    if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
        lines[#lines] = nil
    end
    return lines
end
M.split_lines = split_lines

-- ── line cursor ───────────────────────────────────────────────────────────
-- `offset` is the 1-based byte index of the next unconsumed character; `column` is its VIRTUAL
-- column, where a tab advances to the next multiple of four. The two are not interchangeable, and
-- conflating them is the classic way tab-indented list items and code blocks come out wrong.

---@class MdParserState
---@field lines     string[]
---@field line_no   integer
---@field line      string
---@field offset    integer
---@field column    integer
---@field next_nonspace integer
---@field next_nonspace_column integer
---@field indent    integer
---@field indented  boolean
---@field blank     boolean
---@field partial_tab boolean
---@field doc       MdDocument
---@field tip       MdNode
---@field oldtip    MdNode
---@field last_matched MdNode
---@field all_closed boolean
---@field refmap    table
---@field opts      MdParseOptions

--- Locate the next non-whitespace character on the line and derive the indent from it.
---@param p MdParserState
local function find_next_nonspace(p)
    local i, cols = p.offset, p.column
    while true do
        local c = p.line:sub(i, i)
        if c == " " then
            i, cols = i + 1, cols + 1
        elseif c == "\t" then
            i, cols = i + 1, cols + (4 - cols % 4)
        else
            break
        end
    end
    p.blank = p.line:sub(i, i) == ""
    p.next_nonspace = i
    p.next_nonspace_column = cols
    p.indent = cols - p.column
    p.indented = p.indent >= CODE_INDENT
end

--- Jump the cursor to the next non-whitespace character.
---@param p MdParserState
local function advance_next_nonspace(p)
    p.offset = p.next_nonspace
    p.column = p.next_nonspace_column
    p.partial_tab = false
end

--- Consume `count` characters (`columns = false`) or `count` COLUMNS (`columns = true`).
---
--- The two modes differ only at a tab, and only the column mode can stop in the MIDDLE of one — a
--- list item indented by a tab whose content column falls inside that tab. `partial_tab` records
--- that, and `add_line` turns the unconsumed part back into spaces.
---@param p MdParserState
---@param count integer
---@param columns boolean
local function advance_offset(p, count, columns)
    while count > 0 do
        local c = p.line:sub(p.offset, p.offset)
        if c == "" then
            break
        end
        if c == "\t" then
            local to_tab = 4 - (p.column % 4)
            if columns then
                p.partial_tab = to_tab > count
                local step = math.min(to_tab, count)
                p.column = p.column + step
                p.offset = p.offset + (p.partial_tab and 0 or 1)
                count = count - step
            else
                p.partial_tab = false
                p.column = p.column + to_tab
                p.offset = p.offset + 1
                count = count - 1
            end
        else
            p.partial_tab = false
            p.offset = p.offset + 1
            p.column = p.column + 1
            count = count - 1
        end
    end
end

--- Whether the character at `i` is a space or a tab.
---@param line string
---@param i integer
---@return boolean
local function is_space_or_tab(line, i)
    local c = line:sub(i, i)
    return c == " " or c == "\t"
end

--- Append the rest of the current line to the block that is accepting lines.
---@param p MdParserState
local function add_line(p)
    if p.partial_tab then
        p.offset = p.offset + 1
        p.tip.content = p.tip.content .. (" "):rep(4 - (p.column % 4))
    end
    p.tip.content = p.tip.content .. p.line:sub(p.offset) .. "\n"
end

-- ── tree building ─────────────────────────────────────────────────────────

--- Whether a block of type `t` may hold a child of type `child`.
---@param t string
---@param child string
---@return boolean
local function can_contain(t, child)
    if t == "list" then
        return child == "item"
    end
    return t == "document" or t == "block_quote" or t == "item" or t == "footnote_def"
end

-- Forward declaration: finalizing a block can close its parent, and adding a child can finalize.
local finalize

--- Close every open block from the tip down to (but not including) the last matched container.
---@param p MdParserState
local function close_unmatched(p)
    if p.all_closed then
        return
    end
    while p.oldtip ~= p.last_matched do
        local parent = p.oldtip.parent
        finalize(p, p.oldtip, p.line_no - 1)
        p.oldtip = parent or p.doc
    end
    p.all_closed = true
end

--- Add a new block of type `tag` as a child of the tip, closing blocks that cannot contain it.
---@param p MdParserState
---@param tag string
---@return MdNode
local function add_child(p, tag)
    while not can_contain(p.tip.type, tag) do
        finalize(p, p.tip, p.line_no - 1)
    end
    local node = {
        type = tag,
        children = {},
        content = "",
        open = true,
        line = p.line_no,
        end_line = p.line_no,
        parent = p.tip,
    }
    table.insert(p.tip.children, node)
    p.tip = node
    return node
end

--- Remove `node` from its parent's children (a paragraph that turned out to be nothing but link
--- reference definitions).
---@param node MdNode
local function unlink(node)
    local parent = node.parent
    if not parent then
        return
    end
    for i, child in ipairs(parent.children) do
        if child == node then
            table.remove(parent.children, i)
            return
        end
    end
end

--- Replace `node` in its parent's children with the nodes in `replacements`.
---@param node MdNode
---@param replacements MdNode[]
local function replace(node, replacements)
    local parent = node.parent
    if not parent then
        return
    end
    for i, child in ipairs(parent.children) do
        if child == node then
            table.remove(parent.children, i)
            for k = #replacements, 1, -1 do
                replacements[k].parent = parent
                table.insert(parent.children, i, replacements[k])
            end
            return
        end
    end
end

-- ── GFM pipe tables ───────────────────────────────────────────────────────

--- Split a table row on unescaped `|`, dropping one leading and one trailing empty cell (the
--- optional outer pipes).
---@param s string
---@return string[]
local function split_row(s)
    local cells, buf, i, n = {}, {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "\\" and s:sub(i + 1, i + 1) == "|" then
            -- `\|` is a literal pipe INSIDE a cell; the backslash is consumed here so the inline
            -- scanner does not see an escape of a character it no longer has.
            buf[#buf + 1] = "|"
            i = i + 2
        elseif c == "|" then
            cells[#cells + 1] = table.concat(buf)
            buf = {}
            i = i + 1
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    cells[#cells + 1] = table.concat(buf)
    if #cells > 0 and trim(cells[1]) == "" then
        table.remove(cells, 1)
    end
    if #cells > 0 and trim(cells[#cells]) == "" then
        table.remove(cells)
    end
    return cells
end

--- Read a delimiter row (`| --- | :--: |`) into its per-column alignments.
---@param s string
---@return string[]?
local function delimiter_row(s)
    if not s:find("|", 1, true) then
        return nil
    end
    local cells = split_row(s)
    if #cells == 0 then
        return nil
    end
    local align = {}
    for _, cell in ipairs(cells) do
        local t = trim(cell)
        if not t:match("^:?%-+:?$") then
            return nil
        end
        local left, right = t:sub(1, 1) == ":", t:sub(-1) == ":"
        align[#align + 1] = (left and right and "center") or (left and "left") or (right and "right") or ""
    end
    return align
end

--- Build a table node from a header line, a delimiter row's alignments and the body lines.
---@param header string
---@param align string[]
---@param body string[]
---@param first_line integer
---@param opts MdParseOptions
---@return MdNode
local function build_table(header, align, body, first_line, opts)
    local width = #align
    ---@param text string
    ---@param line integer
    ---@return MdTableRow
    local function row(text, line)
        local cells, raw = {}, split_row(text)
        for c = 1, width do
            -- Table cells are parsed inline HERE, at paragraph finalize (phase one), before the
            -- document's footnote definitions have been gathered — so a `[^ref]` in a cell resolves
            -- against nothing and stays literal, exactly as a link reference in a cell already does.
            -- Emoji needs no such map, so it works in cells.
            cells[c] = polish.run(inline.parse(trim(raw[c] or ""), { strike = opts.strike, emoji = opts.emoji }), opts)
        end
        return { cells = cells, line = line }
    end
    local node = {
        type = "table",
        children = {},
        align = align,
        head = row(header, first_line),
        rows = {},
        line = first_line,
        end_line = first_line + 1 + #body,
    }
    for k, text in ipairs(body) do
        node.rows[k] = row(text, first_line + 1 + k)
    end
    return node
end

--- Try to read a table out of a finished paragraph's lines.
---
--- Detection happens at paragraph FINALIZE rather than as a block start on purpose. A table needs
--- to see its delimiter row, which is the line AFTER its header — and at block-start time the raw
--- next line still carries whatever container prefixes (`> `, an item's indent) the current context
--- strips. By the time a paragraph is finalized those prefixes are already gone from its content,
--- so the two-line lookahead is exact in every container instead of only at the top level.
---@param p MdParserState
---@param block MdNode
---@return boolean  whether the paragraph was replaced
local function try_table(p, block)
    if p.opts.tables == false or not block.content:find("|", 1, true) then
        return false
    end
    local lines = {}
    for line in block.content:gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    for i = 1, #lines - 1 do
        local header = lines[i]
        if header:find("|", 1, true) then
            local align = delimiter_row(lines[i + 1])
            if align and #split_row(header) == #align then
                local body = {}
                for k = i + 2, #lines do
                    body[#body + 1] = lines[k]
                end
                local table_line = block.line + i - 1
                local nodes = {}
                if i > 1 then
                    local para = {
                        type = "paragraph",
                        children = {},
                        content = table.concat(lines, "\n", 1, i - 1) .. "\n",
                        line = block.line,
                        end_line = table_line - 1,
                    }
                    nodes[#nodes + 1] = para
                end
                nodes[#nodes + 1] = build_table(header, align, body, table_line, p.opts)
                replace(block, nodes)
                return true
            end
        end
    end
    return false
end

-- ── finalize ──────────────────────────────────────────────────────────────

--- Whether `block` (or its last descendant list/item) ended on a blank line — the test that decides
--- whether a list is tight or loose.
---@param block MdNode?
---@return boolean
local function ends_with_blank_line(block)
    while block do
        if block.last_line_blank then
            return true
        end
        if (block.type == "list" or block.type == "item") and not block.blank_checked then
            block.blank_checked = true
            block = block.children[#block.children]
        else
            return false
        end
    end
    return false
end

--- Close a block and do whatever its type owes at the end: strip reference definitions off a
--- paragraph, split the info string off a fence, decide a list's tightness.
---@param p MdParserState
---@param block MdNode
---@param line_no integer
finalize = function(p, block, line_no)
    local above = block.parent
    block.open = false
    block.end_line = math.max(line_no, block.line)

    if block.type == "paragraph" then
        -- Every leading link reference definition is consumed into the document's refmap and
        -- disappears from the output. `block.line` moves with it so the surviving text keeps its
        -- true source line for the scroll anchor.
        while block.content:sub(1, 1) == "[" do
            local consumed = inline.parse_reference(block.content, p.refmap)
            if consumed == 0 then
                break
            end
            local eaten = block.content:sub(1, consumed)
            local _, newlines = eaten:gsub("\n", "")
            block.line = block.line + newlines
            block.content = block.content:sub(consumed + 1)
        end
        if block.content:match("^[ \t\n]*$") then
            unlink(block)
        else
            try_table(p, block)
        end
    elseif block.type == "code_block" then
        if block.fenced then
            local first, rest = block.content:match("^([^\n]*)\n?(.*)$")
            block.info = inline.unescape(trim(first or ""))
            block.language = block.info:match("^[^%s]+")
            block.content = rest or ""
        else
            -- Trailing blank lines are not part of an indented code block.
            block.content = strip_trailing_blank_lines(block.content) .. "\n"
        end
    elseif block.type == "html_block" then
        block.content = strip_trailing_blank_lines(block.content)
    elseif block.type == "list" then
        for _, item in ipairs(block.children) do
            if ends_with_blank_line(item) and item ~= block.children[#block.children] then
                block.tight = false
                break
            end
            for k, sub in ipairs(item.children) do
                if ends_with_blank_line(sub) and (item ~= block.children[#block.children] or k ~= #item.children) then
                    block.tight = false
                    break
                end
            end
            if block.tight == false then
                break
            end
        end
    end

    p.tip = above or p.doc
end

-- ── block starts ──────────────────────────────────────────────────────────
-- Each returns 0 (no match), 1 (a CONTAINER was opened — keep looking for starts inside it) or
-- 2 (a LEAF was opened — stop looking). Order matters and mirrors the spec's precedence.

--- `> ` — a block quote.
---@param p MdParserState
---@return integer
local function start_block_quote(p)
    if p.indented or p.line:sub(p.next_nonspace, p.next_nonspace) ~= ">" then
        return 0
    end
    advance_next_nonspace(p)
    advance_offset(p, 1, false)
    if is_space_or_tab(p.line, p.offset) then
        advance_offset(p, 1, true)
    end
    close_unmatched(p)
    add_child(p, "block_quote")
    return 1
end

--- `### ` — an ATX heading.
---@param p MdParserState
---@return integer
local function start_atx_heading(p)
    if p.indented then
        return 0
    end
    local rest = p.line:sub(p.next_nonspace)
    local hashes = rest:match("^(#+)")
    if not hashes or #hashes > 6 then
        return 0
    end
    local after = rest:sub(#hashes + 1, #hashes + 1)
    if after ~= "" and after ~= " " and after ~= "\t" then
        return 0
    end
    advance_next_nonspace(p)
    advance_offset(p, #hashes, false)
    close_unmatched(p)
    local node = add_child(p, "heading")
    node.level = #hashes
    -- A closing sequence of `#` is decoration, not text — but only when it is set off by a space.
    node.content = (p.line:sub(p.offset):gsub("^[ \t]*#+[ \t]*$", ""):gsub("[ \t]+#+[ \t]*$", ""))
    node.content = trim(node.content)
    advance_offset(p, #p.line - p.offset + 1, false)
    return 2
end

--- ``` ``` ``` or `~~~` — a fenced code block.
---@param p MdParserState
---@return integer
local function start_fenced_code(p)
    if p.indented then
        return 0
    end
    local rest = p.line:sub(p.next_nonspace)
    local fence = rest:match("^(```+)") or rest:match("^(~~~+)")
    if not fence then
        return 0
    end
    -- A backtick fence's info string may not contain a backtick, or `` `foo` `` in a paragraph
    -- would open a code block.
    if fence:sub(1, 1) == "`" and rest:sub(#fence + 1):find("`", 1, true) then
        return 0
    end
    close_unmatched(p)
    local node = add_child(p, "code_block")
    node.fenced = true
    node.fence_length = #fence
    node.fence_char = fence:sub(1, 1)
    node.fence_offset = p.indent
    advance_next_nonspace(p)
    advance_offset(p, #fence, false)
    return 2
end

--- Which of the spec's seven HTML block types starts at `rest`, if any.
---@param rest string
---@param in_paragraph boolean
---@return integer?
local function html_block_type(rest, in_paragraph)
    if rest:sub(1, 1) ~= "<" then
        return nil
    end
    local lower = rest:lower()
    if
        lower:match("^<script[%s>]")
        or lower:match("^<pre[%s>]")
        or lower:match("^<style[%s>]")
        or lower:match("^<textarea[%s>]")
    then
        return 1
    end
    if lower == "<script" or lower == "<pre" or lower == "<style" or lower == "<textarea" then
        return 1
    end
    if rest:sub(1, 4) == "<!--" then
        return 2
    end
    if rest:sub(1, 2) == "<?" then
        return 3
    end
    if rest:match("^<![%a]") then
        return 4
    end
    if rest:sub(1, 9) == "<![CDATA[" then
        return 5
    end
    local tag = lower:match("^</?([%a][%w%-]*)")
    if tag and BLOCK_TAGS[tag] then
        local after = lower:match("^</?[%a][%w%-]*(.*)$")
        if after == "" or after:match("^[%s]") or after:match("^>") or after:match("^/>") then
            return 6
        end
    end
    if not in_paragraph then
        -- Type 7: a complete open or closing tag, alone on its line.
        local after = inline.match_html_tag(rest, 1)
        if after and rest:sub(after):match("^[ \t]*$") then
            return 7
        end
    end
    return nil
end

--- `<div>`, `<!-- … -->`, … — an HTML block.
---@param p MdParserState
---@param container MdNode
---@return integer
local function start_html_block(p, container)
    if p.indented then
        return 0
    end
    local kind = html_block_type(p.line:sub(p.next_nonspace), container.type == "paragraph")
    if not kind then
        return 0
    end
    close_unmatched(p)
    local node = add_child(p, "html_block")
    node.html_block_type = kind
    return 2
end

--- `===` / `---` under a paragraph — a setext heading.
---@param p MdParserState
---@param container MdNode
---@return integer
local function start_setext_heading(p, container)
    if p.indented or container.type ~= "paragraph" then
        return 0
    end
    local marker = p.line:sub(p.next_nonspace):match("^(=+)[ \t]*$")
        or p.line:sub(p.next_nonspace):match("^(%-+)[ \t]*$")
    if not marker then
        return 0
    end
    close_unmatched(p)
    -- A setext underline still lets the paragraph's leading reference definitions through.
    while container.content:sub(1, 1) == "[" do
        local consumed = inline.parse_reference(container.content, p.refmap)
        if consumed == 0 then
            break
        end
        local _, newlines = container.content:sub(1, consumed):gsub("\n", "")
        container.line = container.line + newlines
        container.content = container.content:sub(consumed + 1)
    end
    if container.content == "" then
        return 0
    end
    container.type = "heading"
    container.level = marker:sub(1, 1) == "=" and 1 or 2
    container.content = trim(container.content)
    p.tip = container
    advance_offset(p, #p.line - p.offset + 1, false)
    return 2
end

--- `***` / `---` / `___` — a thematic break.
---@param p MdParserState
---@return integer
local function start_thematic_break(p)
    if p.indented then
        return 0
    end
    local rest = p.line:sub(p.next_nonspace)
    local marker = rest:sub(1, 1)
    if marker ~= "*" and marker ~= "-" and marker ~= "_" then
        return 0
    end
    local count = 0
    for i = 1, #rest do
        local c = rest:sub(i, i)
        if c == marker then
            count = count + 1
        elseif c ~= " " and c ~= "\t" then
            return 0
        end
    end
    if count < 3 then
        return 0
    end
    close_unmatched(p)
    add_child(p, "thematic_break")
    advance_offset(p, #p.line - p.offset + 1, false)
    return 2
end

--- Read a list marker at the cursor, and how far its content is indented.
---@param p MdParserState
---@param container MdNode
---@return table?  { ordered, bullet, start, delimiter, padding, marker_offset }
local function parse_list_marker(p, container)
    if p.indented then
        return nil
    end
    local rest = p.line:sub(p.next_nonspace)
    local data = { marker_offset = p.indent, tight = true }
    local marker = rest:match("^([%*%+%-])")
    local number, delim
    if marker then
        data.ordered = false
        data.bullet = marker
    else
        number, delim = rest:match("^(%d%d?%d?%d?%d?%d?%d?%d?%d?)([%.%)])")
        -- An ordered list may only interrupt a paragraph when it starts at 1.
        if not number or (container.type == "paragraph" and number ~= "1") then
            return nil
        end
        data.ordered = true
        data.start = tonumber(number)
        data.delimiter = delim
        marker = number .. delim
    end
    -- The marker must be followed by whitespace or end of line.
    local after = p.next_nonspace + #marker
    local nextc = p.line:sub(after, after)
    if nextc ~= "" and nextc ~= " " and nextc ~= "\t" then
        return nil
    end
    -- A list may only interrupt a paragraph when its first item has content.
    if container.type == "paragraph" and p.line:sub(after):match("^[ \t]*$") then
        return nil
    end

    advance_next_nonspace(p)
    advance_offset(p, #marker, true)
    local spaces_start_col, spaces_start_offset = p.column, p.offset
    repeat
        advance_offset(p, 1, true)
    until p.column - spaces_start_col >= 5 or not is_space_or_tab(p.line, p.offset)
    local blank_item = p.line:sub(p.offset, p.offset) == ""
    local spaces_after = p.column - spaces_start_col
    if spaces_after >= 5 or spaces_after < 1 or blank_item then
        -- Five or more spaces means the content is an indented code block inside the item, and an
        -- empty item has no content column to speak of: either way the content starts one space
        -- after the marker.
        data.padding = #marker + 1
        p.column, p.offset = spaces_start_col, spaces_start_offset
        if is_space_or_tab(p.line, p.offset) then
            advance_offset(p, 1, true)
        end
    else
        data.padding = #marker + spaces_after
    end
    return data
end

--- Whether an item's marker belongs to the same list as the one already open.
---@param a table
---@param b table
---@return boolean
local function lists_match(a, b)
    return a.ordered == b.ordered and a.bullet == b.bullet and a.delimiter == b.delimiter
end

--- `- ` / `1. ` — a list item (opening a new list when the marker changed).
---@param p MdParserState
---@param container MdNode
---@return integer
local function start_list_item(p, container)
    if p.indented and container.type ~= "list" then
        return 0
    end
    local data = parse_list_marker(p, container)
    if not data then
        return 0
    end
    close_unmatched(p)
    if p.tip.type ~= "list" or not lists_match(p.tip.list_data, data) then
        local list = add_child(p, "list")
        list.list_data = data
        list.ordered = data.ordered
        list.start = data.start
        list.bullet = data.bullet
        list.delimiter = data.delimiter
        list.tight = true
    end
    local item = add_child(p, "item")
    item.list_data = data
    return 1
end

--- Four spaces of indentation outside a paragraph — an indented code block.
---@param p MdParserState
---@return integer
local function start_indented_code(p)
    if not p.indented or p.tip.type == "paragraph" or p.blank then
        return 0
    end
    advance_offset(p, CODE_INDENT, true)
    close_unmatched(p)
    add_child(p, "code_block")
    return 2
end

--- `[^label]: …` — a footnote definition. A CONTAINER (like a list item): the text after the
--- marker opens its first paragraph, and lines indented under it continue it, so a note may run to
--- several paragraphs. Like a link reference definition it does NOT interrupt a paragraph — a
--- `[^1]:` line right under a line of prose is lazy continuation, not a definition.
---@param p MdParserState
---@param container MdNode
---@return integer
local function start_footnote_def(p, container)
    if p.indented or p.opts.footnotes ~= true or container.type == "paragraph" then
        return 0
    end
    local rest = p.line:sub(p.next_nonspace)
    local marker = rest:match("^(%[%^[^%]%s]+%]:)")
    if not marker then
        return 0
    end
    close_unmatched(p)
    advance_next_nonspace(p)
    advance_offset(p, #marker, false)
    -- One optional space after the colon is part of the marker, not the note's content.
    if is_space_or_tab(p.line, p.offset) then
        advance_offset(p, 1, true)
    end
    local node = add_child(p, "footnote_def")
    node.fn_label = marker:match("^%[%^([^%]%s]+)%]:$")
    -- Continuation lines are the ones indented into the definition; GFM's own rule is a 4-space
    -- content indent, matching a top-level list item.
    node.fn_indent = CODE_INDENT
    return 1
end

local BLOCK_STARTS = {
    start_block_quote,
    start_atx_heading,
    start_fenced_code,
    start_html_block,
    start_setext_heading,
    start_thematic_break,
    start_footnote_def,
    start_list_item,
    start_indented_code,
}

-- ── continuation ──────────────────────────────────────────────────────────

--- Case-insensitive plain-text search.
---@param haystack string
---@param needle string
---@return boolean
local function ifind(haystack, needle)
    return haystack:lower():find(needle, 1, true) ~= nil
end

--- Whether the current line closes an HTML block of type 1..5.
---@param kind integer
---@param rest string
---@return boolean
local function html_block_closes(kind, rest)
    if kind == 1 then
        return ifind(rest, "</script>")
            or ifind(rest, "</pre>")
            or ifind(rest, "</style>")
            or ifind(rest, "</textarea>")
    elseif kind == 2 then
        return rest:find("-->", 1, true) ~= nil
    elseif kind == 3 then
        return rest:find("?>", 1, true) ~= nil
    elseif kind == 4 then
        return rest:find(">", 1, true) ~= nil
    elseif kind == 5 then
        return rest:find("]]>", 1, true) ~= nil
    end
    return false
end

--- Ask a container whether the current line continues it, consuming its prefix when it does.
---@param p MdParserState
---@param block MdNode
---@return integer  0 = continues, 1 = does not, 2 = the block just ended and the line is consumed
local function continue_block(p, block)
    local t = block.type
    if t == "document" or t == "list" then
        return 0
    elseif t == "block_quote" then
        if not p.indented and p.line:sub(p.next_nonspace, p.next_nonspace) == ">" then
            advance_next_nonspace(p)
            advance_offset(p, 1, false)
            if is_space_or_tab(p.line, p.offset) then
                advance_offset(p, 1, true)
            end
            return 0
        end
        return 1
    elseif t == "item" then
        if p.blank then
            if #block.children == 0 then
                return 1 -- a blank line right after an empty item ends it
            end
            advance_next_nonspace(p)
            return 0
        elseif p.indent >= block.list_data.marker_offset + block.list_data.padding then
            advance_offset(p, block.list_data.marker_offset + block.list_data.padding, true)
            return 0
        end
        return 1
    elseif t == "code_block" then
        if block.fenced then
            local rest = p.line:sub(p.next_nonspace)
            local close = not p.indented
                and rest:sub(1, 1) == block.fence_char
                and (rest:match("^(`+)[ \t]*$") or rest:match("^(~+)[ \t]*$"))
            if close and #close >= block.fence_length then
                finalize(p, block, p.line_no)
                return 2
            end
            -- The closing fence may be indented up to the opening fence's own indent, so the same
            -- amount of leading whitespace is stripped from every content line.
            local i = block.fence_offset
            while i > 0 and is_space_or_tab(p.line, p.offset) do
                advance_offset(p, 1, true)
                i = i - 1
            end
            return 0
        end
        if p.indent >= CODE_INDENT then
            advance_offset(p, CODE_INDENT, true)
        elseif p.blank then
            advance_next_nonspace(p)
        else
            return 1
        end
        return 0
    elseif t == "footnote_def" then
        -- Same continuation shape as a list item: a blank line is tolerated once there is content,
        -- and a line indented to the definition's content column keeps feeding it.
        if p.blank then
            if #block.children == 0 then
                return 1
            end
            advance_next_nonspace(p)
            return 0
        elseif p.indent >= block.fn_indent then
            advance_offset(p, block.fn_indent, true)
            return 0
        end
        return 1
    elseif t == "html_block" then
        return (p.blank and (block.html_block_type == 6 or block.html_block_type == 7)) and 1 or 0
    elseif t == "paragraph" then
        return p.blank and 1 or 0
    end
    return 1 -- heading, thematic_break, table: single-line blocks
end

-- Lines that could possibly start a block; anything else is plain paragraph text. `[` is here for a
-- `[^label]:` footnote definition (only that leads anywhere — a `[foo]: /url` link reference falls
-- through every start and is handled at paragraph finalize, exactly as before).
local MAYBE_SPECIAL = "^[#`~%*%+_=<>%-%d%[]"

--- Run one source line through the whole algorithm.
---@param p MdParserState
---@param ln string
local function incorporate_line(p, ln)
    local all_matched = true
    ---@type MdNode
    local container = p.doc
    p.oldtip = p.tip
    p.offset, p.column, p.blank, p.partial_tab = 1, 0, false, false
    p.line_no = p.line_no + 1
    p.line = ln

    -- 1. Walk the open containers, consuming each one's prefix.
    while true do
        local last = container.children[#container.children]
        if not (last and last.open) then
            break
        end
        container = last
        find_next_nonspace(p)
        local result = continue_block(p, container)
        if result == 1 then
            all_matched = false
        elseif result == 2 then
            return -- the container consumed the whole line (a closing fence)
        end
        if not all_matched then
            container = container.parent
            break
        end
    end

    p.all_closed = (container == p.oldtip)
    p.last_matched = container

    -- 2. Look for new block starts at what is left of the line.
    local matched_leaf = container.type ~= "paragraph" and ACCEPTS_LINES[container.type]
    while not matched_leaf do
        find_next_nonspace(p)
        if not p.indented and not p.line:sub(p.next_nonspace):match(MAYBE_SPECIAL) then
            advance_next_nonspace(p)
            break
        end
        local i = 1
        while i <= #BLOCK_STARTS do
            local res = BLOCK_STARTS[i](p, container)
            if res == 1 then
                container = p.tip
                break
            elseif res == 2 then
                container = p.tip
                matched_leaf = true
                break
            end
            i = i + 1
        end
        if i > #BLOCK_STARTS then
            advance_next_nonspace(p)
            break
        end
    end

    -- 3. Whatever remains is text for the deepest open block.
    if not p.all_closed and not p.blank and p.tip.type == "paragraph" then
        -- Lazy continuation: a paragraph swallows a line that failed to match its containers.
        add_line(p)
        return
    end

    close_unmatched(p)
    -- The block that just ended on this blank line is the one a list's tightness test asks about,
    -- so the flag has to land on the CHILD, not only on the container that survived.
    if p.blank and #container.children > 0 then
        container.children[#container.children].last_line_blank = true
    end
    local t = container.type
    -- A blank line "belongs" to a block for tightness purposes unless the block is one that a
    -- blank line cannot end.
    local last_line_blank = p.blank
        and not (
            t == "block_quote"
            or (t == "code_block" and container.fenced)
            or (t == "item" and #container.children == 0 and container.line == p.line_no)
        )
    local cont = container
    while cont do
        cont.last_line_blank = last_line_blank
        cont = cont.parent
    end

    if ACCEPTS_LINES[t] then
        add_line(p)
        if
            t == "html_block"
            and container.html_block_type <= 5
            and html_block_closes(container.html_block_type, p.line:sub(p.offset))
        then
            finalize(p, container, p.line_no)
        end
    elseif p.offset <= #p.line and not p.blank then
        container = add_child(p, "paragraph")
        advance_next_nonspace(p)
        add_line(p)
    end
end

-- ── phase two: inline parsing ─────────────────────────────────────────────

--- A GFM task-list marker at the start of an item's first paragraph.
---@param node MdNode
local function extract_task(node)
    local first = node.children[1]
    if not first or (first.type ~= "paragraph" and first.type ~= "heading") then
        return
    end
    local box, rest = first.content:match("^%[([ xX])%]%s(.*)$")
    if not box then
        box, rest = first.content:match("^%[([ xX])%]()$")
        rest = ""
    end
    if box then
        node.task = (box == " ") and "unchecked" or "checked"
        first.content = rest or ""
    end
end

--- Collect every footnote definition into the document's `footnotes` map (first definition of a
--- label wins) and record the first-seen order. Runs before inline parsing so a `[^label]` anywhere
--- in the document — even one that appears BEFORE its definition — can resolve.
---@param node MdNode
---@param doc MdDocument
local function collect_footnotes(node, doc)
    if node.type == "footnote_def" and node.fn_label then
        local key = node.fn_label:lower()
        if not doc.footnotes[key] then
            doc.footnotes[key] = node
            doc.footnote_order[#doc.footnote_order + 1] = key
        end
    end
    for _, child in ipairs(node.children or {}) do
        collect_footnotes(child, doc)
    end
end

--- Walk the finished block tree and parse every leaf's accumulated text into inline nodes.
---@param node MdNode
---@param refmap table
---@param opts MdParseOptions
---@param footnotes table?  the collected footnote map, so `[^label]` resolves (nil = feature off)
local function parse_inlines(node, refmap, opts, footnotes)
    if node.type == "paragraph" or node.type == "heading" then
        node.inlines = polish.run(
            inline.parse(
                trim(node.content or ""),
                { refmap = refmap, strike = opts.strike, emoji = opts.emoji, footnotes = footnotes }
            ),
            opts
        )
    end
    if node.type == "item" and opts.task_lists == true then
        extract_task(node)
    end
    for _, child in ipairs(node.children or {}) do
        parse_inlines(child, refmap, opts, footnotes)
    end
    node.parent = nil
    node.list_data = nil
    node.last_line_blank = nil
    node.blank_checked = nil
    node.open = nil
end

--- Parse a markdown document.
---
--- Never raises on user input: an empty file, a blank file, an unterminated construct and CRLF line
--- endings are all valid inputs that produce a valid (possibly empty) tree.
---@param text string|string[]  the document text, or its lines
---@param opts MdParseOptions?
---@return MdDocument
function M.parse(text, opts)
    opts = opts or {}
    local lines = type(text) == "table" and text or split_lines(text --[[@as string]])
    ---@type MdDocument
    local doc = {
        type = "document",
        children = {},
        content = "",
        open = true,
        line = 1,
        end_line = math.max(#lines, 1),
        refmap = {},
        footnotes = {},
        footnote_order = {},
    }
    ---@type MdParserState
    local p = {
        lines = lines,
        line_no = 0,
        line = "",
        offset = 1,
        column = 0,
        next_nonspace = 1,
        next_nonspace_column = 0,
        indent = 0,
        indented = false,
        blank = false,
        partial_tab = false,
        doc = doc,
        tip = doc,
        oldtip = doc,
        last_matched = doc,
        all_closed = true,
        refmap = doc.refmap,
        opts = opts,
    }
    for _, ln in ipairs(lines) do
        incorporate_line(p, ln)
    end
    while p.tip and p.tip ~= doc do
        finalize(p, p.tip, #lines)
    end
    finalize(p, doc, #lines)
    -- Footnote definitions must be gathered before inline parsing so a reference resolves against
    -- the WHOLE document (a `[^1]` may precede its `[^1]:`). The map is passed to the inline scanner
    -- only when the feature is on; off, references and definitions both stay literal.
    if opts.footnotes == true then
        collect_footnotes(doc, doc)
    end
    parse_inlines(doc, doc.refmap, opts, opts.footnotes == true and doc.footnotes or nil)
    return doc
end

return M
