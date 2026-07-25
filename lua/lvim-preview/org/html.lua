-- lvim-preview.org.html: one HTML renderer over the org document tree.
--
-- Deliberately SEPARATE from the parser. The parser knows only org; this module knows only how a
-- browser wants to see it. Anything that is specific to how lvim-preview presents a page lives on
-- this side of the line, so the two other planned consumers of the parser (an in-buffer decorator,
-- an editing/agenda plugin) can take the tree and never load a line of HTML code.
--
-- What this renderer commits to, because the rest of the plugin depends on it:
--   * `data-source-line` + `class="source-line"` on every block element, straight from the node's
--     parsed line. That is the SAME attribute the markdown path emits, so the browser client's
--     `scrollToLine` needs no org-specific branch and editor→browser scroll sync is exact.
--   * `<pre><code class="language-X">` for `#+BEGIN_SRC X`, which is what the client's highlight.js
--     pass selects — and what makes `#+BEGIN_SRC mermaid` a diagram, since the mermaid pass
--     selects `.language-mermaid`.
--   * LaTeX fragments keep their `$…$` delimiters and environments are wrapped in `$$…$$`, because
--     the client's KaTeX auto-render pass scans for delimiters. Escaping is safe here: the browser
--     decodes `&amp;` back to `&` in textContent, which is what KaTeX reads.
--
-- Pure Lua, pure string work — callable from the libuv HTTP callback.
--
---@module "lvim-preview.org.html"

local inline = require("lvim-preview.org.inline")

local M = {}

---@class OrgHtmlOptions
---@field source_lines boolean?  emit data-source-line anchors (default true)
---@field title_block  boolean?  render #+TITLE / #+AUTHOR / #+DATE as a page header (default true)
---@field footnotes    boolean?  render the collected footnote definitions at the end (default true)
---@field heading_shift integer? add this to every headline level (default 0)

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }

--- Escape text for an HTML text node or a double-quoted attribute.
---@param s string?
---@return string
local function esc(s)
    return (tostring(s or ""):gsub('[&<>"]', ESCAPES))
end
M.escape = esc

--- Escape a URL for an `href`/`src` attribute. `javascript:` and `data:` targets are neutralised:
--- a preview renders whatever the file on disk says, and a document is not a trust boundary we
--- can vouch for.
---@param url string
---@return string
local function esc_url(url)
    local low = url:lower():gsub("%s", "")
    if low:match("^javascript:") or low:match("^data:text/html") or low:match("^vbscript:") then
        return "#"
    end
    return esc(url)
end

-- The HTML attributes an `#+ATTR_HTML:` line may set. A DELIBERATE allow-list: `#+ATTR_HTML:` in
-- org can carry any attribute, but a document is not a trust boundary (see esc_url), so an arbitrary
-- attribute from a file — `onclick`, `style`, `srcset` — must not reach the page. Width/height/class/
-- alt/title/id cover the real uses (sizing an image, tagging a table) with no scripting surface.
---@type fun(nodes: table, ctx: table): string  forward decl (defined below; figcaption_of needs it)
local render_inline

local ATTR_ALLOW = { width = true, height = true, class = true, alt = true, title = true, id = true }

--- Parse an `#+ATTR_HTML:` value (`:width 300 :class foo bar`) into an HTML attribute string,
--- keeping only the allow-listed keys and escaping every value. Returns "" for nil / nothing usable.
---@param attr string?  the raw `#+ATTR_HTML:` value
---@return string  a leading-space attribute string, or ""
local function attr_html_to_string(attr)
    if type(attr) ~= "string" or attr == "" then
        return ""
    end
    local out = {}
    -- `:key value...` pairs; a value runs until the next `:key` or end of line.
    for key, value in attr:gmatch(":([%w_-]+)%s+([^:]*)") do
        key = key:lower()
        if ATTR_ALLOW[key] then
            out[#out + 1] = (' %s="%s"'):format(key, esc(vim.trim(value)))
        end
    end
    return table.concat(out)
end

--- A `<figcaption>` for a node's affiliated caption, or "" when it has none.
---@param node OrgNode
---@param ctx table
---@return string
local function figcaption_of(node, ctx)
    if not node.caption or node.caption == "" then
        return ""
    end
    return ("<figcaption>%s</figcaption>"):format(render_inline(inline.parse(node.caption), ctx))
end

--- The ` class="source-line" data-source-line="N"` attribute pair, or "" when anchors are off.
---@param node OrgNode
---@param opts OrgHtmlOptions
---@return string
local function anchor(node, opts)
    if opts.source_lines == false or not node.line then
        return ""
    end
    return (' class="source-line" data-source-line="%d"'):format(node.line)
end

--- Merge `extra` classes into an anchor attribute string (one `class` attribute, never two).
---@param node OrgNode
---@param opts OrgHtmlOptions
---@param extra string
---@return string
local function anchor_with(node, opts, extra)
    if opts.source_lines == false or not node.line then
        return extra ~= "" and (' class="%s"'):format(extra) or ""
    end
    return (' class="source-line%s" data-source-line="%d"'):format(extra ~= "" and (" " .. extra) or "", node.line)
end

-- Forward declarations: blocks and inline containers recurse into each other.
-- (render_inline is forward-declared above, next to figcaption_of that needs it.)
local render_nodes

--- Render a list of inline object nodes.
---@param nodes table[]?
---@param ctx table
---@return string
render_inline = function(nodes, ctx)
    local out = {}
    for _, node in ipairs(nodes or {}) do
        local t = node.type
        if t == "text" then
            out[#out + 1] = esc(node.value)
        elseif t == "bold" then
            out[#out + 1] = "<strong>" .. render_inline(node.children, ctx) .. "</strong>"
        elseif t == "italic" then
            out[#out + 1] = "<em>" .. render_inline(node.children, ctx) .. "</em>"
        elseif t == "underline" then
            out[#out + 1] = '<u class="org-underline">' .. render_inline(node.children, ctx) .. "</u>"
        elseif t == "strike" then
            out[#out + 1] = "<del>" .. render_inline(node.children, ctx) .. "</del>"
        elseif t == "code" then
            out[#out + 1] = '<code class="org-code">' .. esc(node.value) .. "</code>"
        elseif t == "verbatim" then
            out[#out + 1] = '<code class="org-verbatim">' .. esc(node.value) .. "</code>"
        elseif t == "superscript" then
            out[#out + 1] = "<sup>" .. render_inline(node.children, ctx) .. "</sup>"
        elseif t == "subscript" then
            out[#out + 1] = "<sub>" .. render_inline(node.children, ctx) .. "</sub>"
        elseif t == "line_break" then
            out[#out + 1] = "<br>\n"
        elseif t == "latex_fragment" then
            -- Verbatim, delimiters included: the KaTeX pass reads textContent.
            out[#out + 1] = esc(node.value)
        elseif t == "timestamp" then
            out[#out + 1] = ('<span class="org-timestamp org-timestamp-%s">%s</span>'):format(
                node.active and "active" or "inactive",
                esc(node.value)
            )
        elseif t == "target" then
            out[#out + 1] = ('<span id="%s" class="org-target"></span>'):format(esc(node.value))
        elseif t == "footnote_reference" then
            local label = node.label or ("anon" .. tostring(#out))
            local n = ctx.footnote_number[label]
            if not n then
                n = ctx.footnote_next
                ctx.footnote_next = ctx.footnote_next + 1
                ctx.footnote_number[label] = n
                if node.inline then
                    ctx.footnote_inline[label] = node.inline
                    ctx.footnote_extra[#ctx.footnote_extra + 1] = label
                end
            end
            out[#out + 1] = ('<sup class="org-footref"><a id="fnr.%s" href="#fn.%s">%d</a></sup>'):format(
                esc(label),
                esc(label),
                n
            )
        elseif t == "link" then
            local path = node.path
            -- `*Heading` and `#custom-id` are in-document links; everything else is a URL or a
            -- path relative to the served document.
            if path:sub(1, 1) == "*" then
                path = "#" .. path:sub(2):gsub("%s+", "-"):lower()
            elseif path:sub(1, 1) == "#" then
                path = path
            end
            if node.image then
                out[#out + 1] = ('<img src="%s" alt="%s" class="org-image">'):format(esc_url(path), esc(node.raw))
            else
                local text = node.description and render_inline(node.description, ctx) or esc(node.path)
                out[#out + 1] = ('<a href="%s">%s</a>'):format(esc_url(path), text)
            end
        elseif node.children then
            out[#out + 1] = render_inline(node.children, ctx)
        elseif node.value then
            out[#out + 1] = esc(node.value)
        end
    end
    return table.concat(out)
end

--- Render a list item's body. An item whose whole content is ONE paragraph is rendered TIGHT —
--- its inline content directly, with no `<p>` wrapper — which is what a reader expects from
--- `- one` and what keeps a simple list from getting a paragraph's vertical margin per row. An
--- item with a continuation paragraph, a nested list or a block keeps the full block rendering.
---@param item OrgNode
---@param ctx table
---@return string
local function render_item_body(item, ctx)
    local kids = item.children or {}
    if #kids == 1 and kids[1].type == "paragraph" then
        return render_inline(kids[1].children, ctx)
    end
    return render_nodes(kids, ctx)
end

--- Render a list node — `<dl>` when its items carry description terms, else `<ul>`/`<ol>`.
---@param node OrgNode
---@param ctx table
---@return string
local function render_list(node, ctx)
    local opts = ctx.opts
    local items = node.items or {}
    -- Org decides "this is a description list" from the FIRST item, and so do we. Scanning for
    -- ANY item with a `::` turned a perfectly ordinary list into a <dl> the moment one of its
    -- rows happened to contain a double colon — which silently ate that list's nesting and its
    -- checkboxes.
    local described = items[1] ~= nil and items[1].term ~= nil

    local out = {}
    if described then
        out[#out + 1] = "<dl" .. anchor_with(node, opts, "org-dl") .. ">"
        for _, item in ipairs(items) do
            if item.term then
                out[#out + 1] = "<dt" .. anchor(item, opts) .. ">" .. render_inline(item.term, ctx) .. "</dt>"
                out[#out + 1] = "<dd>" .. render_item_body(item, ctx) .. "</dd>"
            else
                out[#out + 1] = "<dd" .. anchor(item, opts) .. ">" .. render_item_body(item, ctx) .. "</dd>"
            end
        end
        out[#out + 1] = "</dl>"
        return table.concat(out, "\n")
    end

    local tag = node.ordered and "ol" or "ul"
    local start = ""
    local first = items[1]
    if node.ordered and first and first.counter and first.counter ~= "1" then
        start = (' start="%s"'):format(esc(first.counter))
    end
    out[#out + 1] = "<" .. tag .. anchor_with(node, opts, "org-list") .. start .. ">"
    for _, item in ipairs(items) do
        local classes = item.checkbox and ("org-checkbox-item org-checkbox-" .. item.checkbox) or ""
        out[#out + 1] = "<li" .. anchor_with(item, opts, classes) .. ">"
        if item.checkbox then
            out[#out + 1] = ('<input type="checkbox" disabled%s> '):format(
                item.checkbox == "checked" and " checked" or ""
            )
        end
        -- A `::` on an item of a list that is NOT a description list (org decides that from the
        -- first item) still has to show its term — dropping it would lose text the author wrote.
        if item.term then
            out[#out + 1] = "<strong>" .. render_inline(item.term, ctx) .. "</strong> "
        end
        out[#out + 1] = render_item_body(item, ctx)
        out[#out + 1] = "</li>"
    end
    out[#out + 1] = "</" .. tag .. ">"
    return table.concat(out, "\n")
end

--- Render a table. Rows with DIFFERING cell counts are padded to the widest row rather than
--- rejected — a half-typed row is the normal state of a table you are editing, and a preview that
--- drops the table while you type it is useless.
---@param node OrgNode
---@param ctx table
---@return string
local function render_table(node, ctx)
    local width = 0
    for _, row in ipairs(node.rows or {}) do
        if row.cells and #row.cells > width then
            width = #row.cells
        end
    end
    local out = { "<table" .. attr_html_to_string(node.attr_html) .. anchor_with(node, ctx.opts, "org-table") .. ">" }
    -- An affiliated `#+CAPTION:` becomes the table's own <caption> (the first child of <table>, per
    -- HTML), rendered inline so `*bold*` in a caption works.
    if node.caption and node.caption ~= "" then
        out[#out + 1] = ("<caption>%s</caption>"):format(render_inline(inline.parse(node.caption), ctx))
    end
    local header_rows = node.has_header and node.header_rows or 0
    local seen, in_body = 0, false
    if header_rows > 0 then
        out[#out + 1] = "<thead>"
    end
    for _, row in ipairs(node.rows or {}) do
        if row.kind == "data" then
            seen = seen + 1
            local cell_tag = seen <= header_rows and "th" or "td"
            if seen > header_rows and not in_body then
                if header_rows > 0 then
                    out[#out + 1] = "</thead>"
                end
                out[#out + 1] = "<tbody>"
                in_body = true
            end
            local cells = { "<tr>" }
            for c = 1, width do
                local content = row.cells[c] and render_inline(row.cells[c], ctx) or ""
                cells[#cells + 1] = ("<%s>%s</%s>"):format(cell_tag, content, cell_tag)
            end
            cells[#cells + 1] = "</tr>"
            out[#out + 1] = table.concat(cells)
        end
    end
    if header_rows > 0 and not in_body then
        out[#out + 1] = "</thead>"
    elseif in_body then
        out[#out + 1] = "</tbody>"
    end
    out[#out + 1] = "</table>"
    return table.concat(out, "\n")
end

--- Render a `#+BEGIN_…` block.
---@param node OrgNode
---@param ctx table
---@return string
local function render_block(node, ctx)
    local opts = ctx.opts
    local name = node.name
    if name == "src" then
        local lang = node.language and (' class="language-' .. esc(node.language) .. '"') or ""
        return ("<pre%s><code%s>%s</code></pre>"):format(
            anchor_with(node, opts, "src-block"),
            lang,
            esc(node.value or "")
        )
    elseif name == "example" then
        return ("<pre%s>%s</pre>"):format(anchor_with(node, opts, "example"), esc(node.value or ""))
    elseif name == "export" then
        -- `#+BEGIN_EXPORT html` is the author explicitly asking for raw HTML; any other export
        -- backend's body is not HTML and is shown as text instead of injected.
        if (node.params or ""):lower():match("^html") then
            return node.value or ""
        end
        return ("<pre%s>%s</pre>"):format(anchor_with(node, opts, "example"), esc(node.value or ""))
    elseif name == "verse" then
        local lines = {}
        for line in ((node.value or "") .. "\n"):gmatch("([^\n]*)\n") do
            lines[#lines + 1] = render_inline(inline.parse(line), ctx)
        end
        return ("<p%s>%s</p>"):format(anchor_with(node, opts, "org-verse"), table.concat(lines, "<br>\n"))
    elseif name == "comment" then
        return "" -- a comment block is not output, by org's own rule
    elseif name == "quote" then
        return ("<blockquote%s>\n%s\n</blockquote>"):format(anchor(node, opts), render_nodes(node.children, ctx))
    elseif name == "center" then
        return ("<div%s>\n%s\n</div>"):format(anchor_with(node, opts, "org-center"), render_nodes(node.children, ctx))
    end
    -- An unknown block name keeps its body and says what it was.
    return ("<div%s>\n%s\n</div>"):format(
        anchor_with(node, opts, "org-block org-block-" .. esc(name)),
        render_nodes(node.children, ctx)
    )
end

--- Render one block node.
---@param node OrgNode
---@param ctx table
---@return string
local function render_node(node, ctx)
    local opts = ctx.opts
    local t = node.type

    if t == "paragraph" then
        local body = render_inline(node.children, ctx)
        if body == "" then
            return ""
        end
        -- An affiliated `#+CAPTION:` (and `#+ATTR_HTML:`) on a paragraph that is JUST an image wraps
        -- it in a <figure> with a <figcaption> and applies the safe attributes to the <img>. Only a
        -- lone image gets the figure treatment — a caption on a text paragraph has no figure to make,
        -- so it degrades to a plain <p> (the caption is then simply not shown, as org does for prose).
        local lone_image = #node.children == 1 and node.children[1].type == "link" and node.children[1].image
        if node.caption and lone_image then
            local attrs = attr_html_to_string(node.attr_html)
            if attrs ~= "" then
                body = body:gsub("<img", "<img" .. attrs:gsub("%%", "%%%%"), 1)
            end
            return ("<figure%s>%s%s</figure>"):format(anchor(node, opts), body, figcaption_of(node, ctx))
        end
        return ("<p%s>%s</p>"):format(anchor(node, opts), body)
    elseif t == "headline" then
        local level = math.min(6, math.max(1, node.level + (opts.heading_shift or 0)))
        local parts = {}
        if node.todo then
            parts[#parts + 1] = ('<span class="todo-keyword %s %s">%s</span> '):format(
                esc(node.todo),
                node.todo_done and "org-done" or "org-todo",
                esc(node.todo)
            )
        end
        if node.priority then
            parts[#parts + 1] = ('<span class="org-priority">#%s</span> '):format(esc(node.priority))
        end
        parts[#parts + 1] = render_inline(node.title, ctx)
        for _, tag in ipairs(node.tags or {}) do
            parts[#parts + 1] = (' <span class="org-tag">%s</span>'):format(esc(tag))
        end
        local id = inline.to_text(node.title):gsub("%s+", "-"):lower():gsub("[^%w%-_]", "")
        local out = ('<h%d id="%s"%s>%s</h%d>'):format(level, esc(id), anchor(node, opts), table.concat(parts), level)
        local body = render_nodes(node.children, ctx)
        return body ~= "" and (out .. "\n" .. body) or out
    elseif t == "list" then
        return render_list(node, ctx)
    elseif t == "table" then
        return render_table(node, ctx)
    elseif t == "block" then
        return render_block(node, ctx)
    elseif t == "fixed_width" then
        return ("<pre%s>%s</pre>"):format(anchor_with(node, opts, "example"), esc(node.value or ""))
    elseif t == "horizontal_rule" then
        return ("<hr%s>"):format(anchor(node, opts))
    elseif t == "latex_environment" then
        -- Wrapped in the display delimiter the client's auto-render pass scans for; KaTeX itself
        -- understands `\begin{align}` and friends once it is handed display math.
        return ("<div%s>$$%s$$</div>"):format(anchor_with(node, opts, "org-latex"), esc(node.value or ""))
    elseif t == "drawer" then
        return ("<details%s><summary>%s</summary>\n%s\n</details>"):format(
            anchor_with(node, opts, "org-drawer"),
            esc(node.name),
            render_nodes(node.children, ctx)
        )
    elseif t == "property_drawer" then
        local rows = {}
        for _, key in ipairs(node.order or {}) do
            rows[#rows + 1] = ("<dt>%s</dt><dd>%s</dd>"):format(esc(key), esc(node.properties[key]))
        end
        return ('<details%s><summary>PROPERTIES</summary><dl class="org-props">%s</dl></details>'):format(
            anchor_with(node, opts, "org-drawer org-properties"),
            table.concat(rows)
        )
    elseif t == "comment" or t == "unknown" then
        -- Not displayed (org comments are not exported; an `unknown` line is a construct nothing
        -- claimed), but not lost either: `--` is broken up so the body can never terminate the
        -- HTML comment it sits in.
        return ("<!-- %s -->"):format((node.value or ""):gsub("%-%-", "- -"):gsub(">", "&gt;"))
    elseif t == "keyword" or t == "footnote_definition" then
        -- Keywords are metadata (the title block reads them); footnote definitions are collected
        -- and rendered once, at the end.
        return ""
    end
    return ""
end

--- Render a list of block nodes, dropping the empties so the output has no blank lines.
---@param nodes OrgNode[]?
---@param ctx table
---@return string
render_nodes = function(nodes, ctx)
    local out = {}
    for _, node in ipairs(nodes or {}) do
        local html = render_node(node, ctx)
        if html ~= "" then
            out[#out + 1] = html
        end
    end
    return table.concat(out, "\n")
end

--- The `#+TITLE:` / `#+SUBTITLE:` / `#+AUTHOR:` / `#+DATE:` header block.
---@param doc OrgDocument
---@param ctx table
---@return string
local function render_title_block(doc, ctx)
    local kw = doc.keywords or {}
    if not (kw.title or kw.subtitle or kw.author or kw.date) then
        return ""
    end
    local out = { '<header class="org-title-block">' }
    if kw.title then
        out[#out + 1] = '<h1 class="org-title">' .. render_inline(inline.parse(kw.title), ctx) .. "</h1>"
    end
    if kw.subtitle then
        out[#out + 1] = '<p class="org-subtitle">' .. render_inline(inline.parse(kw.subtitle), ctx) .. "</p>"
    end
    local meta = {}
    if kw.author then
        meta[#meta + 1] = render_inline(inline.parse(kw.author), ctx)
    end
    if kw.date then
        meta[#meta + 1] = render_inline(inline.parse(kw.date), ctx)
    end
    if #meta > 0 then
        out[#out + 1] = '<p class="org-meta">' .. table.concat(meta, " &middot; ") .. "</p>"
    end
    out[#out + 1] = "</header>"
    return table.concat(out, "\n")
end

--- The footnotes section: every definition that was REFERENCED, in reference order, plus any
--- inline definitions collected while rendering.
---@param doc OrgDocument
---@param ctx table
---@return string
local function render_footnotes(doc, ctx)
    local labels = {}
    for label, n in pairs(ctx.footnote_number) do
        labels[#labels + 1] = { label = label, n = n }
    end
    if #labels == 0 then
        return ""
    end
    table.sort(labels, function(a, b)
        return a.n < b.n
    end)
    local out = { '<section class="org-footnotes"><h2>Footnotes</h2>' }
    for _, entry in ipairs(labels) do
        local def = doc.footnotes and doc.footnotes[entry.label]
        local body
        if def then
            body = render_nodes(def.children, ctx)
        elseif ctx.footnote_inline[entry.label] then
            body = "<p>" .. render_inline(ctx.footnote_inline[entry.label], ctx) .. "</p>"
        else
            body = '<p class="org-footnote-missing">(no definition)</p>'
        end
        out[#out + 1] = ('<div class="org-footdef" id="fn.%s"><sup><a href="#fnr.%s">%d</a></sup> %s</div>'):format(
            esc(entry.label),
            esc(entry.label),
            entry.n,
            body
        )
    end
    out[#out + 1] = "</section>"
    return table.concat(out, "\n")
end

--- Render a parsed org document to an HTML fragment (no `<html>`/`<body>` — the caller owns the
--- page shell).
---@param doc OrgDocument
---@param opts OrgHtmlOptions?
---@return string html
function M.render(doc, opts)
    opts = opts or {}
    local ctx = {
        opts = opts,
        footnote_number = {},
        footnote_inline = {},
        footnote_extra = {},
        footnote_next = 1,
    }
    local body = render_nodes(doc.children, ctx)
    local parts = {}
    if opts.title_block ~= false then
        local header = render_title_block(doc, ctx)
        if header ~= "" then
            parts[#parts + 1] = header
        end
    end
    if body ~= "" then
        parts[#parts + 1] = body
    end
    if opts.footnotes ~= false then
        local notes = render_footnotes(doc, ctx)
        if notes ~= "" then
            parts[#parts + 1] = notes
        end
    end
    return table.concat(parts, "\n")
end

return M
