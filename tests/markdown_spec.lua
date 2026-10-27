-- The block parser, held to the rules its own header says it follows.
--
-- The module opens by explaining why it is NOT a line-oriented state machine: `> - a` opens two
-- containers on one line, a paragraph continues across a line that would otherwise start one, an
-- item's content column depends on the spaces after its bullet, and a tab counts to the next
-- multiple of four. Those are the cases a line-oriented parser gets wrong, so those are the cases
-- here.
--
-- Two further design rules are stated as properties rather than examples. TOLERANCE: no input is
-- rejected and nothing is dropped -- an unclosed fence runs to the end, a ragged table row keeps
-- its cells, a malformed reference definition stays paragraph text, an unresolved inline stays the
-- literal text the author typed. And every node carries the ABSOLUTE 1-based source lines it came
-- from, which is what makes editor-to-browser scroll sync exact instead of proportional.

local parser = require("lvim-preview.markdown.parser")
local inline = require("lvim-preview.markdown.inline")

--- The document tree of `text`.
---@param text string
---@return table
local function parse(text)
    return parser.parse(text)
end

--- The types of a node's children, in order.
---@param node table
---@return string[]
local function kinds(node)
    local out = {}
    for i, c in ipairs(node.children or {}) do
        out[i] = c.type
    end
    return out
end

--- Descend a chain of first children and return the node at the end.
---@param node table
---@param depth integer
---@return table
local function down(node, depth)
    local cur = node
    for _ = 1, depth do
        cur = (cur.children or {})[1]
        truthy(cur, "the tree is shallower than " .. depth)
    end
    return cur
end

--- Every node of the tree, flat.
---@param node table
---@param out? table[]
---@return table[]
local function all_nodes(node, out)
    out = out or {}
    out[#out + 1] = node
    for _, c in ipairs(node.children or {}) do
        all_nodes(c, out)
    end
    return out
end

describe("lvim-preview: blocks a line-oriented parser gets wrong")

it("one line can open two containers", function()
    -- down() counts levels from the DOCUMENT, so the quote itself is level 1.
    local doc = parse("> - a\n")
    eq({ "block_quote" }, kinds(doc))
    eq("block_quote", down(doc, 1).type)
    eq("list", down(doc, 2).type)
    eq("item", down(doc, 3).type)
    eq("paragraph", down(doc, 4).type)
end)

it("a paragraph inside a quote continues on a line without the marker", function()
    -- Lazy continuation: the second line has no `>` and is still part of the quoted paragraph.
    local doc = parse("> quoted para\ncontinued lazily\n")
    eq({ "block_quote" }, kinds(doc))
    local para = down(doc, 2)
    eq("paragraph", para.type)
    eq(1, para.line)
    eq(2, para.end_line, "both lines belong to the one paragraph")
    truthy(para.content:match("continued lazily"), vim.inspect(para.content))
end)

it("an item's content column follows the spaces after its bullet", function()
    -- One space after the bullet: the continuation is at column 2. Three: at column 4. Both are
    -- the same list with one item, because each line sits at ITS item's content column.
    for _, src in ipairs({ "- a\n  b\n", "-   a\n    b\n" }) do
        local doc = parse(src)
        eq({ "list" }, kinds(doc), vim.inspect(src))
        local para = down(doc, 3)
        eq("paragraph", para.type)
        eq(2, para.end_line, "the continuation line belongs to the item: " .. vim.inspect(src))
    end
end)

it("a tab counts to the next multiple of four, not as one column", function()
    -- An indented code block needs four columns of indent. One tab reaches exactly four, so a
    -- tab-indented line IS code -- and a tab read as one column would make it a paragraph.
    eq({ "code_block" }, kinds(parse("\tcode\n")))
    -- One space then a tab: the tab advances to the next multiple of four, so this is four columns
    -- too. Counting the tab as one column gives two, and a paragraph.
    eq({ "code_block" }, kinds(parse(" \tcode\n")))
    -- Four spaces are the same column by a different route, which is the point of measuring
    -- columns rather than characters.
    eq({ "code_block" }, kinds(parse("    code\n")))
    -- Three characters of indent is not code, however they are written.
    eq({ "paragraph" }, kinds(parse("   text\n")))
end)

it("a tab inside a list item is measured the same way", function()
    -- `- a` puts its content column at 2, and a tab from column 0 reaches 4 -- still inside the
    -- item, so the line continues its paragraph. (Unlike the cases above, this one does not
    -- distinguish the tab rule on its own: at one column per tab the line would land at column 1,
    -- which is still a lazy continuation of the same paragraph. It is here for the shape, not as
    -- the measurement.)
    local doc = parse("- a\n\tb\n")
    eq({ "list" }, kinds(doc))
    eq("paragraph", down(doc, 3).type)
end)

describe("lvim-preview: nothing is rejected and nothing is dropped")

it("an unclosed fence runs to the end of its container", function()
    local doc = parse("```lua\ncode here\n")
    eq({ "code_block" }, kinds(doc))
    eq(1, doc.children[1].line)
    eq(2, doc.children[1].end_line, "the fence was never closed, so it owns the rest")
end)

it("a ragged table row keeps its cells, padded to the header", function()
    local doc = parse("| a | b | c |\n|---|---|---|\n| 1 |\n")
    local t = doc.children[1]
    eq("table", t.type)
    eq(3, #t.head.cells)
    eq(1, #t.rows)
    eq(3, #t.rows[1].cells, "a short row is padded, never discarded")
    eq("1", t.rows[1].cells[1][1].value)
    eq({}, t.rows[1].cells[2], "and the missing cells are empty, not nil")
end)

it("the alignment row is read per column", function()
    local t = parse("| a | b | c |\n|---|:-:|--:|\n| 1 | 2 | 3 |\n").children[1]
    eq({ "", "center", "right" }, t.align)
end)

it("a malformed reference definition stays paragraph text", function()
    local doc = parse("[foo]: \n")
    eq({ "paragraph" }, kinds(doc), "it is not a definition, so it is what it looks like")
end)

it("an inline that does not resolve stays the text the author typed", function()
    local doc = parse("see [missing]\n")
    local para = doc.children[1]
    local text = inline.to_text(para.inlines)
    truthy(text:find("[missing]", 1, true), "the brackets are the author's own: " .. vim.inspect(text))
end)

it("an empty document is a document", function()
    local doc = parse("")
    eq("document", doc.type)
    eq({}, kinds(doc))
end)

describe("lvim-preview: every node knows its source lines")

it("the lines are absolute and 1-based", function()
    local doc = parse("# Title\n\nsome text\n\n## Second\n")
    eq(1, doc.children[1].line)
    eq(1, doc.children[1].end_line)
    eq(3, doc.children[2].line, "the blank line is not part of the paragraph")
    eq(5, doc.children[3].line)
end)

it("no node claims a line outside the document", function()
    local src = "# T\n\n> - a\n>   b\n\n```\nx\n```\n\n| a |\n|---|\n| 1 |\n"
    local lines = select(2, src:gsub("\n", "")) -- how many newlines, i.e. lines of text
    for _, node in ipairs(all_nodes(parse(src))) do
        if node.line then
            truthy(node.line >= 1, node.type .. " starts at " .. tostring(node.line))
            truthy(
                node.end_line <= lines,
                ("%s claims lines %s-%s of a %d-line document"):format(
                    node.type,
                    tostring(node.line),
                    tostring(node.end_line),
                    lines
                )
            )
            truthy(node.end_line >= node.line, node.type .. " ends before it starts")
        end
    end
end)

it("a child's lines sit inside its parent's", function()
    local doc = parse("> - a\n>   b\n")
    local function check(node)
        for _, c in ipairs(node.children or {}) do
            if node.line and c.line then
                truthy(
                    c.line >= node.line and c.end_line <= node.end_line,
                    ("%s[%d-%d] is not inside %s[%d-%d]"):format(
                        c.type,
                        c.line,
                        c.end_line,
                        node.type,
                        node.line,
                        node.end_line
                    )
                )
            end
            check(c)
        end
    end
    check(doc)
end)

describe("lvim-preview: inline parsing is a second pass")

it("a reference defined LATER in the document still resolves", function()
    -- This is why inline parsing cannot happen while the blocks are being read.
    local doc = parse("see [foo]\n\n[foo]: /url\n")
    local para = doc.children[1]
    truthy(para.inlines, "the paragraph carries its parsed inlines")

    local found
    for _, node in ipairs(para.inlines) do
        if node.type == "link" then
            found = node
        end
    end
    truthy(found, "the definition comes after the use: " .. vim.inspect(para.inlines))
    eq("/url", found.dest, "the link node carries its destination")
end)

it("emphasis and strong are nested nodes, not text", function()
    local nodes = inline.parse("plain **bold** and *em*", { refmap = {} })
    local types = {}
    for _, n in ipairs(nodes) do
        types[#types + 1] = n.type
    end
    truthy(vim.tbl_contains(types, "strong"), vim.inspect(types))
    truthy(vim.tbl_contains(types, "emph"), vim.inspect(types))
end)

it("to_text gives back what the author typed, markup aside", function()
    local nodes = inline.parse("a **b** c", { refmap = {} })
    eq("a b c", inline.to_text(nodes))
end)

it("a reference with no definition is left alone", function()
    local nodes = inline.parse("see [nope]", { refmap = {} })
    for _, n in ipairs(nodes) do
        truthy(n.type ~= "link", "there is nothing to link to: " .. vim.inspect(nodes))
    end
    truthy(inline.to_text(nodes):find("[nope]", 1, true))
end)

describe("lvim-preview: the parser touches no editor state")

it("nothing in the block parser reaches for vim.api or vim.fn", function()
    -- The module says so, and it matters: it is called from a libuv HTTP callback, where either
    -- would be E5560.
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
    for _, name in ipairs({ "parser.lua", "inline.lua" }) do
        local path = root .. "/lua/lvim-preview/markdown/" .. name
        local src = table.concat(vim.fn.readfile(path), "\n")
        -- Comments mention them; what must not appear is a CALL.
        for _, bad in ipairs({ "vim%.api%.nvim_", "vim%.fn%.[%w_]+%(" }) do
            local line_no = 0
            for line in src:gmatch("[^\n]*") do
                line_no = line_no + 1
                local code = line:gsub("%-%-.*$", "")
                eq(nil, code:match(bad), ("%s:%d calls into the editor: %s"):format(name, line_no, line))
            end
        end
    end
end)
