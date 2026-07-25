-- lvim-preview.org.parser: the BLOCK-level org parser — org text in, a document TREE out.
--
-- Org's block level is line-regular (a construct is decided by how a line starts), so this is a
-- line-oriented state machine rather than a grammar, exactly like lvim-rest's .http parser. The
-- inline/object level is a different shape and lives in `lvim-preview.org.inline`.
--
-- TOLERANCE IS A DESIGN RULE, not an accident: no input is ever rejected and nothing is dropped.
-- An unclosed `#+BEGIN_SRC` runs to the end of its section; an unknown block name is kept as a
-- generic block with its body; an unknown `#+KEYWORD:` is kept in `document.keywords`; a drawer
-- with no `:END:` closes at the section boundary; a table row with the wrong number of cells is
-- kept as it was written. A previewer that silently loses a paragraph because the author was
-- mid-edit is worse than one that shows something slightly odd.
--
-- Every node carries `line` / `end_line`, the ABSOLUTE 1-based source lines it came from. That is
-- what the HTML renderer turns into `data-source-line` anchors, which is what makes editor→browser
-- scroll sync exact rather than proportional. Nested parses (a list item's body, a quote block)
-- run on a dedented COPY of the lines with a parallel array of their original line numbers, so
-- indentation can be stripped without ever losing the mapping back to the buffer.
--
-- Pure Lua, pure string work: no vim.api / vim.fn, so it is callable from the libuv HTTP callback
-- and portable out of this plugin (see `lvim-preview.org`).
--
---@module "lvim-preview.org.parser"

local inline = require("lvim-preview.org.inline")

local M = {}

local trim = inline.trim

---@class OrgParseOptions
---@field todo_keywords string[]?  Keyword set treated as a TODO state on a headline.

---@class OrgTableRow
---@field kind  "data"|"rule"
---@field cells table[][]?  per cell, its inline nodes (absent for a rule row)
---@field line  integer

--- ONE node shape for the whole tree, with every construct's fields optional. Deliberately not a
--- union of per-type classes: consumers walk the tree by `type` and read the fields that type
--- documents (see `lvim-preview.org` for the type→field table), and a single class keeps that
--- walk simple in both Lua and the language server.
---@class OrgNode
---@field type        string      node type (see `lvim-preview.org` for the full list)
---@field line        integer     1-based first source line of the node
---@field end_line    integer     1-based last source line of the node
---@field children    OrgNode[]?  block children, or inline nodes for inline containers
---@field caption     string?     affiliated `#+CAPTION:` value, attached to the following block
---@field attr_html   string?     affiliated `#+ATTR_HTML:` value (`:width 300 :class foo`)
---@field image       boolean?    link node: the target is an image to embed
---@field value       string?     raw text for verbatim nodes (src/example/fixed-width/latex/unknown)
---@field level       integer?    headline: its depth
---@field todo        string?     headline: its TODO keyword
---@field todo_done   boolean?    headline: whether that keyword is a DONE state
---@field priority    string?     headline: its priority letter
---@field tags        string[]?   headline: its tags
---@field title       table[]?    headline: its title, as inline nodes
---@field properties  table<string, string>?  headline / property_drawer: the property map
---@field order       string[]?   property_drawer: property keys in document order
---@field ordered     boolean?    list: whether it is numbered
---@field items       OrgNode[]?  list: its items
---@field bullet      string?     list_item: the bullet as written
---@field counter     string?     list_item: an ordered item's number
---@field checkbox    string?     list_item: "unchecked" | "checked" | "partial"
---@field term        table[]?    list_item: a description item's term, as inline nodes
---@field rows        OrgTableRow[]?  table: its rows
---@field has_header  boolean?    table: whether a rule separates a header
---@field header_rows integer?    table: how many leading rows are header rows
---@field name        string?     block / drawer: its name
---@field params      string?     block: the text after `#+BEGIN_NAME`
---@field language    string?     block: a src block's language
---@field closed      boolean?    block: whether its `#+END_` was found
---@field key         string?     keyword: the lowercased key
---@field label       string?     footnote_definition: its label

---@class OrgDocument : OrgNode
---@field keywords table<string, string>       `#+KEY: value` in document order, lowercased keys
---@field footnotes table<string, OrgNode>     footnote definitions by label
---@field footnote_order string[]              labels in first-definition order

-- Block names whose body is org markup and is parsed recursively.
local NESTED_BLOCK = { quote = true, center = true }
-- Block names whose body is taken verbatim.
local VERBATIM_BLOCK = { src = true, example = true, export = true, comment = true, verse = true }

--- Split text into lines, tolerating CRLF and a missing trailing newline.
---
--- A stray `\r` left on the end of every line would leak into headings, code blocks and table
--- cells and break every pattern anchored with `$`, so it is stripped here once rather than
--- guarded against in twenty patterns.
---@param text string
---@return string[]
local function split_lines(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = (line:gsub("\r$", ""))
    end
    -- The trailing "" produced by a text that already ended in a newline is not a real line.
    if #lines > 0 and lines[#lines] == "" and text:sub(-1) == "\n" then
        lines[#lines] = nil
    end
    return lines
end
M.split_lines = split_lines

--- Leading-whitespace width of a line (a tab counts as one column — org itself is not stricter,
--- and list nesting only needs a consistent ordering).
---@param line string
---@return integer
local function indent_of(line)
    local ws = line:match("^([ \t]*)")
    return #ws
end

---@class OrgParseState
---@field lines string[]    the lines of the current scope, possibly dedented
---@field nums  integer[]   nums[i] = the absolute source line of lines[i]
---@field i     integer     the cursor
---@field opts  OrgParseOptions

--- A sub-scope over `state`'s lines from `from` to `to`, with `dedent` leading columns removed.
---@param state OrgParseState
---@param from integer
---@param to integer
---@param dedent integer
---@return OrgParseState
local function sub_state(state, from, to, dedent)
    local lines, nums = {}, {}
    for k = from, to do
        local l = state.lines[k]
        lines[#lines + 1] = dedent > 0 and l:sub(dedent + 1) or l
        nums[#nums + 1] = state.nums[k]
        -- A line shorter than the dedent (a blank inside an indented item) becomes "" — correct.
    end
    return { lines = lines, nums = nums, i = 1, opts = state.opts }
end

--- The absolute source line of scope index `k` (falling back to the last known line at EOF, so
--- an `end_line` is never nil for a construct that ran to the end of its scope).
---@param state OrgParseState
---@param k integer
---@return integer
local function num(state, k)
    return state.nums[k] or state.nums[#state.nums] or 1
end

-- Forward declaration: blocks and lists are mutually recursive.
local parse_blocks

-- ── line classification ───────────────────────────────────────────────────

--- A headline: one or more `*` at column 0 followed by a space (or a bare `*` line).
---@param line string
---@return integer? level, string? rest
local function match_headline(line)
    local stars, rest = line:match("^(%*+)%s+(.*)$")
    if stars then
        return #stars, rest
    end
    stars = line:match("^(%*+)$")
    if stars then
        return #stars, ""
    end
    return nil
end

--- A list bullet: `-`, `+`, an indented `*`, or `1.` / `1)`.
---
--- A `*` bullet is only a bullet when it is INDENTED — at column 0 it is a headline, and org
--- resolves the ambiguity the same way.
---
--- `marker` is the bullet's KIND (`-`, `+`, `*`, `.`, `)`), not its text. Org starts a NEW list
--- when the marker changes at the same indentation, so `- a` followed by `+ b` is two lists and
--- `1. a` followed by `2) b` is two lists — comparing the whole bullet text would never see that,
--- because an ordered bullet's text is its counter.
---@param line string
---@return { indent: integer, bullet: string, marker: string, ordered: boolean, counter: string?, rest: string, offset: integer }?
local function match_bullet(line)
    local ws, marker, rest = line:match("^([ \t]*)([-+])%s+(.*)$")
    if marker then
        return {
            indent = #ws,
            bullet = marker,
            marker = marker,
            ordered = false,
            rest = rest,
            offset = #ws + #marker + 1,
        }
    end
    ws, rest = line:match("^([ \t]+)%*%s+(.*)$")
    if rest then
        return { indent = #ws, bullet = "*", marker = "*", ordered = false, rest = rest, offset = #ws + 2 }
    end
    local counter, sep
    ws, counter, sep, rest = line:match("^([ \t]*)(%d+)([%.%)])%s+(.*)$")
    if counter then
        return {
            indent = #ws,
            bullet = counter .. sep,
            marker = sep,
            ordered = true,
            counter = counter,
            rest = rest,
            offset = #ws + #counter + 2,
        }
    end
    -- An empty item (`-` alone on its line) is still an item.
    ws, marker = line:match("^([ \t]*)([-+])$")
    if marker then
        return { indent = #ws, bullet = marker, marker = marker, ordered = false, rest = "", offset = #ws + 1 }
    end
    return nil
end

--- `#+BEGIN_NAME params` (case-insensitive, as org is).
---@param line string
---@return string? name, string? params
local function match_block_begin(line)
    local name, params = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)%s*(.*)$")
    return name and name:lower() or nil, params
end

--- The matching `#+END_NAME`.
---@param line string
---@param name string
---@return boolean
local function is_block_end(line, name)
    local got = line:match("^%s*#%+[Ee][Nn][Dd]_(%S+)%s*$")
    return got ~= nil and got:lower() == name
end

--- A drawer opener `:NAME:` on a line of its own.
---@param line string
---@return string?
local function match_drawer(line)
    local name = line:match("^%s*:([%a][%w_%-]*):%s*$")
    if name and name:upper() ~= "END" then
        return name
    end
    return nil
end

-- ── headline decoration ───────────────────────────────────────────────────

--- Pull the TODO keyword, priority cookie, tags and statistics cookie out of a headline's text.
---@param rest string          everything after the stars
---@param opts OrgParseOptions
---@return table  { todo, todo_done, priority, tags, title }
local function split_headline(rest, opts)
    local out = { tags = {} }
    local text = rest

    -- Tags are a `:a:b:` group at the very end of the line.
    local body, tags = text:match("^(.-)%s+(:[%w_@#%%:]+:)%s*$")
    if not body then
        body, tags = text:match("^()(:[%w_@#%%:]+:)%s*$")
        if body then
            body = ""
        end
    end
    if tags then
        text = body
        for tag in tags:gmatch("[^:]+") do
            out.tags[#out.tags + 1] = tag
        end
    end

    -- TODO keyword: the first word, when it is in the configured set. The set's order decides
    -- what counts as DONE — everything from the first keyword after a `|`, or (with no `|`) the
    -- LAST keyword, which is how `{ "TODO", "DONE" }` behaves without extra configuration.
    local keywords = (opts and opts.todo_keywords) or { "TODO", "DONE" }
    local first = text:match("^(%S+)")
    if first then
        local done_from = nil
        for idx, kw in ipairs(keywords) do
            if kw == "|" then
                done_from = idx + 1
                break
            end
        end
        for idx, kw in ipairs(keywords) do
            if kw ~= "|" and kw == first then
                out.todo = first
                out.todo_done = done_from and idx >= done_from or (not done_from and idx == #keywords)
                text = trim(text:sub(#first + 1))
                break
            end
        end
    end

    -- Priority cookie `[#A]` sits between the keyword and the title.
    local prio, after = text:match("^%[#(%a)%]%s*(.*)$")
    if prio then
        out.priority = prio:upper()
        text = after
    end

    -- A statistics cookie (`[1/3]`, `[50%]`) is metadata, not title text.
    text = trim((text:gsub("%s*%[%d*%%%]%s*$", " "):gsub("%s*%[%d+/%d*%]%s*$", " ")))

    out.title = text
    return out
end

-- ── construct parsers ─────────────────────────────────────────────────────

--- A table: consecutive lines starting with `|`. A `|---` line is a horizontal rule; the rows
--- before the FIRST rule become the header when any data row precedes it.
---@param state OrgParseState
---@return OrgNode
local function parse_table(state)
    local start = state.i
    ---@type OrgTableRow[]
    local rows = {}
    local first_rule = nil
    while state.i <= #state.lines do
        local line = state.lines[state.i]
        if not line:match("^%s*|") then
            break
        end
        local body = trim(line):gsub("^|", ""):gsub("|%s*$", "")
        if trim(line):match("^|[-+|%s]*$") then
            rows[#rows + 1] = { kind = "rule", line = num(state, state.i) }
            first_rule = first_rule or #rows
        else
            local cells = {}
            -- `body` has had its outer pipes removed, so a trailing empty cell is real: split on
            -- every `|` and keep the pieces, differing cell counts included (the renderer pads).
            for cell in (body .. "|"):gmatch("([^|]*)|") do
                cells[#cells + 1] = inline.parse(trim(cell))
            end
            rows[#rows + 1] = { kind = "data", cells = cells, line = num(state, state.i) }
        end
        state.i = state.i + 1
    end
    return {
        type = "table",
        rows = rows,
        has_header = first_rule ~= nil and first_rule > 1,
        header_rows = first_rule and (first_rule - 1) or 0,
        line = num(state, start),
        end_line = num(state, state.i - 1),
    }
end

--- A `#+BEGIN_X … #+END_X` block. An UNCLOSED block runs to the end of the scope rather than
--- being discarded or swallowing the parse.
---@param state OrgParseState
---@param name string
---@param params string
---@return OrgNode
local function parse_block(state, name, params)
    local start = state.i
    state.i = state.i + 1
    local body_from = state.i
    local closed = false
    while state.i <= #state.lines do
        if is_block_end(state.lines[state.i], name) then
            closed = true
            break
        end
        state.i = state.i + 1
    end
    local body_to = state.i - 1
    local node = {
        type = "block",
        name = name,
        params = trim(params or ""),
        closed = closed,
        line = num(state, start),
        end_line = num(state, math.min(state.i, #state.lines)),
    }
    if name == "src" then
        node.language = (params or ""):match("^(%S+)")
    end
    if NESTED_BLOCK[name] then
        node.children = parse_blocks(sub_state(state, body_from, body_to, 0))
    elseif VERBATIM_BLOCK[name] then
        local body = {}
        for k = body_from, body_to do
            -- `,*` / `,#+` are org's escapes for a line that would otherwise close the block.
            body[#body + 1] = (state.lines[k]:gsub("^(%s*),([%*#])", "%1%2"))
        end
        node.value = table.concat(body, "\n")
    else
        -- An unknown block name: keep the body as org markup rather than guessing or dropping.
        node.children = parse_blocks(sub_state(state, body_from, body_to, 0))
    end
    if closed then
        state.i = state.i + 1
    end
    return node
end

--- A `:NAME: … :END:` drawer. `:PROPERTIES:` additionally yields a key→value map, which the
--- caller attaches to the headline it belongs to.
---@param state OrgParseState
---@param name string
---@return OrgNode
local function parse_drawer(state, name)
    local start = state.i
    state.i = state.i + 1
    local body_from = state.i
    while state.i <= #state.lines and not state.lines[state.i]:match("^%s*:[Ee][Nn][Dd]:%s*$") do
        state.i = state.i + 1
    end
    local body_to = state.i - 1
    local node = {
        type = "drawer",
        name = name,
        line = num(state, start),
        end_line = num(state, math.min(state.i, #state.lines)),
    }
    if name:upper() == "PROPERTIES" then
        node.type = "property_drawer"
        node.properties = {}
        node.order = {}
        for k = body_from, body_to do
            local key, value = state.lines[k]:match("^%s*:([^:%s]+):%s*(.*)$")
            if key then
                node.properties[key] = trim(value)
                node.order[#node.order + 1] = key
            end
        end
    else
        node.children = parse_blocks(sub_state(state, body_from, body_to, 0))
    end
    if state.i <= #state.lines then
        state.i = state.i + 1
    end
    return node
end

--- A `\begin{env} … \end{env}` LaTeX environment written at block level. Kept verbatim: the HTML
--- renderer wraps it in `$$…$$` so the existing KaTeX pass renders it.
---@param state OrgParseState
---@param env string
---@return OrgNode
local function parse_latex_environment(state, env)
    local start = state.i
    local body = { state.lines[state.i] }
    state.i = state.i + 1
    while state.i <= #state.lines do
        body[#body + 1] = state.lines[state.i]
        local closed = state.lines[state.i]:match("^%s*\\end{" .. env:gsub("%W", "%%%0") .. "}%s*$")
        state.i = state.i + 1
        if closed then
            break
        end
    end
    return {
        type = "latex_environment",
        value = table.concat(body, "\n"),
        line = num(state, start),
        end_line = num(state, state.i - 1),
    }
end

--- Consecutive `:` fixed-width lines.
---@param state OrgParseState
---@return OrgNode
local function parse_fixed_width(state)
    local start = state.i
    local body = {}
    while state.i <= #state.lines do
        local rest = state.lines[state.i]:match("^%s*:%s?(.*)$")
        if rest == nil or match_drawer(state.lines[state.i]) then
            break
        end
        body[#body + 1] = rest
        state.i = state.i + 1
    end
    return {
        type = "fixed_width",
        value = table.concat(body, "\n"),
        line = num(state, start),
        end_line = num(state, state.i - 1),
    }
end

--- One list at `indent`, with its items and any deeper nested lists.
---
--- An item owns every following line that is indented PAST the bullet's own column, plus blank
--- lines that are followed by such a line. That single rule gives continuation paragraphs, nested
--- lists and mixed markers for free; a marker change at the same indent starts a NEW list, which
--- is what org does (`-` then `+` are two lists).
---@param state OrgParseState
---@param indent integer
---@return OrgNode
local function parse_list(state, indent)
    local start = state.i
    local first = match_bullet(state.lines[state.i])
    local ordered = first and first.ordered or false
    local marker = first and first.marker or "-"
    local items = {}

    while state.i <= #state.lines do
        local b = match_bullet(state.lines[state.i])
        if not b or b.indent ~= indent or b.marker ~= marker then
            break
        end
        local item_start = state.i
        local content_indent = b.offset
        state.i = state.i + 1
        -- Absorb the item's body.
        local last_content = item_start
        while state.i <= #state.lines do
            local line = state.lines[state.i]
            if trim(line) == "" then
                -- A blank only continues the item if an indented line follows it.
                local k = state.i + 1
                while k <= #state.lines and trim(state.lines[k]) == "" do
                    k = k + 1
                end
                if k > #state.lines or indent_of(state.lines[k]) <= indent or match_headline(state.lines[k]) then
                    break
                end
                state.i = k
            elseif indent_of(line) > indent and not match_headline(line) then
                last_content = state.i
                state.i = state.i + 1
            else
                break
            end
        end
        local item_end = math.max(last_content, item_start)

        -- The item's own body: the text after the bullet on the first line, then its indented
        -- continuation dedented to the bullet's content column.
        local body_lines, body_nums = { b.rest }, { num(state, item_start) }
        for k = item_start + 1, item_end do
            local l = state.lines[k]
            body_lines[#body_lines + 1] = #l >= content_indent and l:sub(content_indent + 1) or trim(l)
            body_nums[#body_nums + 1] = num(state, k)
        end

        local item = {
            type = "list_item",
            bullet = b.bullet,
            counter = b.counter,
            line = num(state, item_start),
            end_line = num(state, item_end),
        }
        -- Checkbox and description term are read off the item's first line only.
        local box, after = body_lines[1]:match("^%[([ xX%-])%]%s*(.*)$")
        if box then
            item.checkbox = (box == " " and "unchecked") or (box == "-" and "partial") or "checked"
            body_lines[1] = after
        end
        local term, definition = body_lines[1]:match("^(.-)%s+::%s*(.*)$")
        if term and term ~= "" then
            item.term = inline.parse(term)
            body_lines[1] = definition
        end

        item.children = parse_blocks({ lines = body_lines, nums = body_nums, i = 1, opts = state.opts })
        items[#items + 1] = item
    end

    return {
        type = "list",
        ordered = ordered,
        items = items,
        line = num(state, start),
        end_line = num(state, math.max(state.i - 1, start)),
    }
end

--- A paragraph: consecutive lines that start no other construct. Joined with newlines so the
--- inline scanner can honour org's "emphasis may span one line break" rule.
---@param state OrgParseState
---@return OrgNode
local function parse_paragraph(state)
    local start = state.i
    local parts = {}
    while state.i <= #state.lines do
        local line = state.lines[state.i]
        if
            trim(line) == ""
            or match_headline(line)
            or match_bullet(line)
            or match_block_begin(line)
            or match_drawer(line)
            or line:match("^%s*|")
            or line:match("^%s*#%+")
            or line:match("^%s*#%s")
            or line:match("^%s*#$")
            or line:match("^%s*:%s")
            or line:match("^%s*:$")
            or line:match("^%s*%-%-%-%-%-+%s*$")
            or line:match("^%s*\\begin{%a+}%s*$")
            or line:match("^%[fn:[%w_%-]*%]")
        then
            break
        end
        parts[#parts + 1] = trim(line)
        state.i = state.i + 1
    end
    return {
        type = "paragraph",
        children = inline.parse(table.concat(parts, "\n")),
        line = num(state, start),
        end_line = num(state, state.i - 1),
    }
end

--- Parse every block in a scope until its lines run out.
---@param state OrgParseState
---@return OrgNode[]
parse_blocks = function(state)
    local out = {}
    while state.i <= #state.lines do
        local line = state.lines[state.i]
        local start = state.i

        if trim(line) == "" then
            state.i = state.i + 1
        elseif line:match("^%s*%-%-%-%-%-+%s*$") then
            out[#out + 1] = { type = "horizontal_rule", line = num(state, start), end_line = num(state, start) }
            state.i = state.i + 1
        elseif line:match("^%s*|") then
            out[#out + 1] = parse_table(state)
        else
            local bname, bparams = match_block_begin(line)
            local dname = match_drawer(line)
            local env = line:match("^%s*\\begin{(%a+)}%s*$")
            local fn_label, fn_rest = line:match("^%[fn:([%w_%-]+)%]%s*(.*)$")
            local kw_key, kw_val = line:match("^%s*#%+([%w_%-@]+):%s*(.*)$")
            local bullet = match_bullet(line)

            if bname then
                out[#out + 1] = parse_block(state, bname, bparams or "")
            elseif dname then
                out[#out + 1] = parse_drawer(state, dname)
            elseif env then
                out[#out + 1] = parse_latex_environment(state, env)
            elseif fn_label then
                -- A footnote definition owns everything up to the next definition, headline or
                -- blank-line-then-unindented-line — org's own rule.
                state.i = state.i + 1
                local body_from = state.i
                while state.i <= #state.lines do
                    local l = state.lines[state.i]
                    if match_headline(l) or l:match("^%[fn:[%w_%-]*%]") then
                        break
                    end
                    state.i = state.i + 1
                end
                local sub = sub_state(state, body_from, state.i - 1, 0)
                table.insert(sub.lines, 1, fn_rest or "")
                table.insert(sub.nums, 1, num(state, start))
                out[#out + 1] = {
                    type = "footnote_definition",
                    label = fn_label,
                    children = parse_blocks(sub),
                    line = num(state, start),
                    end_line = num(state, state.i - 1),
                }
            elseif kw_key then
                out[#out + 1] = {
                    type = "keyword",
                    key = kw_key:lower(),
                    value = trim(kw_val or ""),
                    line = num(state, start),
                    end_line = num(state, start),
                }
                state.i = state.i + 1
            elseif line:match("^%s*#%s") or line:match("^%s*#$") then
                local body = {}
                while state.i <= #state.lines do
                    local rest = state.lines[state.i]:match("^%s*#%s?(.*)$")
                    if rest == nil or state.lines[state.i]:match("^%s*#%+") then
                        break
                    end
                    body[#body + 1] = rest
                    state.i = state.i + 1
                end
                out[#out + 1] = {
                    type = "comment",
                    value = table.concat(body, "\n"),
                    line = num(state, start),
                    end_line = num(state, state.i - 1),
                }
            elseif line:match("^%s*:%s") or line:match("^%s*:$") then
                out[#out + 1] = parse_fixed_width(state)
            elseif bullet then
                out[#out + 1] = parse_list(state, bullet.indent)
            else
                local para = parse_paragraph(state)
                if state.i > start then
                    out[#out + 1] = para
                else
                    -- The paragraph scanner refused this line, but no construct above claimed it
                    -- either — a bare `#+`, a `#+BEGIN_` with no name, anything a future stop
                    -- condition rejects without a matching parser. Preserve the line verbatim and
                    -- advance. This is what makes "every line is consumed by exactly one
                    -- construct" a STRUCTURAL guarantee instead of two hand-kept lists that must
                    -- agree; without it the loop below would (correctly) refuse to continue.
                    out[#out + 1] = {
                        type = "unknown",
                        value = line,
                        line = num(state, start),
                        end_line = num(state, start),
                    }
                    state.i = state.i + 1
                end
            end
        end

        -- Absolute safety net: every branch above must consume at least one line. The `unknown`
        -- fallback makes that true by construction, so reaching this is a bug in a construct
        -- parser — fail loudly rather than hang the editor.
        if state.i <= start then
            error("lvim-preview.org.parser: no progress at line " .. tostring(num(state, start)))
        end
    end

    -- Affiliated-keyword pass. `#+CAPTION:` / `#+ATTR_HTML:` describe the element that FOLLOWS them
    -- (org's own term): they are parsed above as ordinary `keyword` nodes, and here they are removed
    -- from the flow and attached to the next real block as `.caption` / `.attr_html`, so the renderer
    -- can emit a <figcaption> / a table <caption> and safe HTML attributes. A caption with nothing
    -- under it (end of scope, or only more keywords) is dropped, exactly as org does on export. Doing
    -- this as a post-pass keeps the nine block-append sites above untouched.
    local affiliated = {}
    local carry = nil
    for _, node in ipairs(out) do
        local key = node.type == "keyword" and node.key
        if key == "caption" or key == "attr_html" then
            carry = carry or {}
            carry[key] = node.value
        elseif node.type == "keyword" then
            -- another affiliated-style keyword we do not consume — flush the carry as its own drop
            -- (it attaches to nothing) and keep the keyword.
            carry = nil
            affiliated[#affiliated + 1] = node
        else
            if carry then
                node.caption = carry.caption
                node.attr_html = carry.attr_html
                carry = nil
            end
            affiliated[#affiliated + 1] = node
        end
    end
    return affiliated
end

--- Parse a headline and everything under it (its own content, then its deeper subtrees).
---@param state OrgParseState
---@param doc OrgDocument
---@return OrgNode
local function parse_headline(state, doc)
    local start = state.i
    local level, rest = match_headline(state.lines[state.i])
    ---@cast level integer
    local head = split_headline(rest or "", state.opts)
    state.i = state.i + 1

    -- Content: every line until a headline of the same level or shallower.
    local content_from = state.i
    while state.i <= #state.lines do
        local lvl = match_headline(state.lines[state.i])
        if lvl and lvl <= level then
            break
        end
        state.i = state.i + 1
    end
    local content_to = state.i - 1

    local node = {
        type = "headline",
        level = level,
        todo = head.todo,
        todo_done = head.todo_done,
        priority = head.priority,
        tags = head.tags,
        title = inline.parse(head.title),
        line = num(state, start),
        end_line = num(state, math.max(content_to, start)),
    }

    -- The subtree is parsed as its own scope, so nested headlines recurse naturally.
    local sub = sub_state(state, content_from, content_to, 0)
    node.children = M.parse_scope(sub, doc)

    -- A `:PROPERTIES:` drawer immediately under the headline is the headline's metadata; lift it
    -- onto the node so consumers (a future lvim-org agenda) read it without walking children.
    for _, child in ipairs(node.children) do
        if child.type == "property_drawer" then
            node.properties = child.properties
            break
        elseif child.type ~= "keyword" then
            break
        end
    end
    return node
end

--- Parse a scope: leading blocks, then any number of headline subtrees.
---@param state OrgParseState
---@param doc OrgDocument
---@return OrgNode[]
function M.parse_scope(state, doc)
    local out = {}
    while state.i <= #state.lines do
        if match_headline(state.lines[state.i]) then
            out[#out + 1] = parse_headline(state, doc)
        else
            -- Everything up to the next headline is ordinary block content.
            local from = state.i
            while state.i <= #state.lines and not match_headline(state.lines[state.i]) do
                state.i = state.i + 1
            end
            for _, node in ipairs(parse_blocks(sub_state(state, from, state.i - 1, 0))) do
                out[#out + 1] = node
                if node.type == "keyword" then
                    -- Later definitions win, matching org's "the last one is in effect".
                    doc.keywords[node.key] = node.value
                elseif node.type == "footnote_definition" then
                    if not doc.footnotes[node.label] then
                        doc.footnote_order[#doc.footnote_order + 1] = node.label
                    end
                    doc.footnotes[node.label] = node
                end
            end
        end
    end
    return out
end

--- Parse an org document.
---
--- Never raises on user input: an empty file, a blank file, an unterminated construct and CRLF
--- line endings are all valid inputs that produce a valid (possibly empty) tree.
---@param text string|string[]  the document text, or its lines
---@param opts OrgParseOptions?
---@return OrgDocument
function M.parse(text, opts)
    local lines = type(text) == "table" and text or split_lines(text --[[@as string]])
    local nums = {}
    for k = 1, #lines do
        nums[k] = k
    end
    ---@type OrgDocument
    local doc = {
        type = "document",
        children = {},
        keywords = {},
        footnotes = {},
        footnote_order = {},
        line = 1,
        end_line = math.max(#lines, 1),
    }
    doc.children = M.parse_scope({ lines = lines, nums = nums, i = 1, opts = opts or {} }, doc)
    return doc
end

return M
