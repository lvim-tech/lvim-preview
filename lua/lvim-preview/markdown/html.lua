-- lvim-preview.markdown.html: one HTML renderer over the markdown document tree.
--
-- Deliberately SEPARATE from the parser, exactly as on the org side. The parser knows only
-- CommonMark; this module knows only how a browser wants to see it. Anything specific to how
-- lvim-preview presents a page lives on this side of the line, so the other planned consumers of the
-- tree (an in-buffer decorator, an outline/TOC reader) can take it and never load a line of HTML.
--
-- What this renderer commits to, because the rest of the plugin depends on it:
--   * `data-source-line` + `class="source-line"` on every block element, straight from the node's
--     parsed line. That is the SAME attribute the org path emits, so the browser client's
--     `scrollToLine` needs no per-format branch and editor→browser scroll sync stays exact.
--   * `<pre><code class="language-X">` for a fenced block with an info string, which is what the
--     client's highlight.js pass selects — and what makes ```` ```mermaid ```` a diagram, since the
--     mermaid pass selects `.language-mermaid`.
--   * Nothing is done to `$…$` / `$$…$$`: they fall out as ordinary text, delimiters intact, which
--     is exactly what the client's KaTeX auto-render pass scans for.
--
-- ── whitespace is not cosmetic here ───────────────────────────────────────────────────────────
-- The line breaks between tags are part of the contract: the CommonMark spec's expected output is
-- byte-exact, and a `<pre>` block's content is whitespace-significant. The renderer therefore keeps
-- an explicit "did the last write end in a newline" flag (`cr`) instead of joining with "\n", which
-- is what lets tight and loose list items differ by exactly the newlines the spec asks for.
--
-- Pure Lua, pure string work — callable from the libuv HTTP callback.
--
---@module "lvim-preview.markdown.html"

local inline = require("lvim-preview.markdown.inline")

local M = {}

---@class MdHtmlOptions
---@field source_lines boolean?  emit data-source-line anchors (default true)
---@field heading_ids  boolean?  give headings an id derived from their text (default true)
---@field heading_shift integer? add this to every heading level (default 0)
---@field xhtml        boolean?  self-close void elements (`<br />`), as the spec's samples do
---@field breaks       boolean?  render a soft line break as `<br>` (default false)
---@field footnotes    boolean?  emit the collected footnote list at the document end (default true)

local ESCAPES = { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;" }

--- Escape text for an HTML text node or a double-quoted attribute.
---@param s string?
---@return string
local function esc(s)
    return (tostring(s or ""):gsub('[&<>"]', ESCAPES))
end
M.escape = esc

--- Escape an ATTRIBUTE value (an `href` or a `title`), leaving character references intact.
---
--- A destination or title reaches the renderer with its `&name;` / `&#nn;` references still written
--- out (see the inline module's header: they are never decoded, because a browser decodes them
--- itself and the rendered page is identical). Escaping them here would turn `&auml;` into the
--- literal text `&auml;` inside the URL, which is the one place the pass-through would have been
--- visible — so the `&` that OPENS a reference is the one `&` that is left alone.
---@param s string?
---@return string
local function esc_attr(s)
    s = tostring(s or "")
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "&" then
            local _, after = s:match("^&(#?%w+);()", i)
            if after then
                out[#out + 1] = s:sub(i, after - 1)
                i = after
            else
                out[#out + 1] = "&amp;"
                i = i + 1
            end
        else
            out[#out + 1] = ESCAPES[c] or c
            i = i + 1
        end
    end
    return table.concat(out)
end
M.escape_attribute = esc_attr

-- Bytes a URI may carry unencoded — `encodeURI`'s set, which is what every CommonMark
-- implementation normalises destinations with.
local URI_SAFE = {}
for ch in ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789;,/?:@&=+$-_.!~*'()#%"):gmatch(".") do
    URI_SAFE[ch] = true
end

--- Percent-encode a link destination, leaving already-valid `%XX` sequences alone.
---
--- `javascript:` and friends are neutralised: a preview renders whatever the file on disk says, and
--- a document is not a trust boundary we can vouch for.
---@param url string
---@return string
local function esc_url(url)
    local low = url:lower():gsub("%s", "")
    if low:match("^javascript:") or low:match("^data:text/html") or low:match("^vbscript:") then
        return "#"
    end
    local out, i, n = {}, 1, #url
    while i <= n do
        local c = url:sub(i, i)
        if c == "%" and url:sub(i + 1, i + 2):match("^%x%x$") then
            out[#out + 1] = url:sub(i, i + 2)
            i = i + 3
        elseif URI_SAFE[c] then
            out[#out + 1] = c
            i = i + 1
        else
            out[#out + 1] = ("%%%02X"):format(url:byte(i))
            i = i + 1
        end
    end
    return esc_attr(table.concat(out))
end
M.escape_url = esc_url

---@class MdRenderCtx
---@field buf   string[]
---@field nl    boolean          whether the last write ended in a newline
---@field opts  MdHtmlOptions
---@field ids   table<string, integer>  heading id → how many times it has been used
---@field fn_defs   table<string, MdNode>  footnote definitions by lower-cased label
---@field fn_number table<string, integer> label → the number it was assigned (reference order)
---@field fn_order  string[]               labels in the order they were first referenced
---@field fn_refs   table<string, integer> label → how many references to it have been rendered

--- Write a literal string.
---@param ctx MdRenderCtx
---@param s string
local function lit(ctx, s)
    if s == "" then
        return
    end
    ctx.buf[#ctx.buf + 1] = s
    ctx.nl = s:sub(-1) == "\n"
end

--- Write a newline unless the output already ends in one.
---@param ctx MdRenderCtx
local function cr(ctx)
    if #ctx.buf > 0 and not ctx.nl then
        lit(ctx, "\n")
    end
end

--- The ` class="source-line" data-source-line="N"` attribute pair, plus any extra classes.
---@param ctx MdRenderCtx
---@param node MdNode|MdTableRow
---@param extra string?
---@return string
local function anchor(ctx, node, extra)
    local classes = extra or ""
    if ctx.opts.source_lines ~= false and node.line then
        classes = classes == "" and "source-line" or ("source-line " .. classes)
        return (' class="%s" data-source-line="%d"'):format(classes, node.line)
    end
    return classes ~= "" and (' class="%s"'):format(classes) or ""
end

--- A stable, unique anchor id for a heading (`## My Heading` → `my-heading`, then `my-heading-1`).
---@param ctx MdRenderCtx
---@param text string
---@return string
local function heading_id(ctx, text)
    local id = text:lower():gsub("[^%w%s%-_]", ""):gsub("%s+", "-")
    if id == "" then
        id = "section"
    end
    local seen = ctx.ids[id]
    ctx.ids[id] = (seen or 0) + 1
    return seen and (id .. "-" .. seen) or id
end

-- Forward declaration: inline containers and blocks recurse into each other through list items.
local render_inlines

--- The plain text of inline nodes, escaped — an image's `alt`, where tags are not allowed.
---@param nodes MdInlineNode[]?
---@return string
local function alt_text(nodes)
    return esc(inline.to_text(nodes))
end

--- Render one inline node.
---@param ctx MdRenderCtx
---@param node MdInlineNode
local function render_inline(ctx, node)
    local t = node.type
    if t == "text" then
        lit(ctx, esc(node.value))
    elseif t == "raw" then
        -- Raw HTML and pass-through character references go out verbatim, by definition.
        lit(ctx, node.value)
    elseif t == "code" then
        lit(ctx, "<code>" .. esc(node.value) .. "</code>")
    elseif t == "emph" then
        lit(ctx, "<em>")
        render_inlines(ctx, node.children)
        lit(ctx, "</em>")
    elseif t == "strong" then
        lit(ctx, "<strong>")
        render_inlines(ctx, node.children)
        lit(ctx, "</strong>")
    elseif t == "strike" then
        lit(ctx, "<s>")
        render_inlines(ctx, node.children)
        lit(ctx, "</s>")
    elseif t == "link" then
        local title = node.title and node.title ~= "" and (' title="' .. esc_attr(node.title) .. '"') or ""
        lit(ctx, ('<a href="%s"%s>'):format(esc_url(node.dest or ""), title))
        render_inlines(ctx, node.children)
        lit(ctx, "</a>")
    elseif t == "image" then
        local title = node.title and node.title ~= "" and (' title="' .. esc_attr(node.title) .. '"') or ""
        lit(
            ctx,
            ('<img src="%s" alt="%s"%s%s>'):format(
                esc_url(node.dest or ""),
                alt_text(node.children),
                title,
                ctx.opts.xhtml and " /" or ""
            )
        )
    elseif t == "footnote_reference" then
        -- A reference is a superscript link to the note. The note is NUMBERED the first time it is
        -- referenced (so the list is in reference order and unreferenced notes get no number), and
        -- each reference gets its own anchor id so the note can link back to every one of them.
        -- A footnote_reference is only ever created with a label (see the inline scanner), so this
        -- is a guaranteed string; the cast tells the checker what the node vocabulary guarantees.
        local key = node.label
        ---@cast key string
        local n = ctx.fn_number[key]
        if not n then
            n = #ctx.fn_order + 1
            ctx.fn_number[key] = n
            ctx.fn_order[#ctx.fn_order + 1] = key
        end
        ctx.fn_refs[key] = (ctx.fn_refs[key] or 0) + 1
        local k = ctx.fn_refs[key]
        local refid = (k == 1) and ("fnref-" .. n) or ("fnref-" .. n .. "-" .. k)
        lit(
            ctx,
            ('<sup class="footnote-ref"><a href="#fn-%d" id="%s" data-footnote-ref>%d</a></sup>'):format(n, refid, n)
        )
    elseif t == "softbreak" then
        lit(ctx, ctx.opts.breaks and (ctx.opts.xhtml and "<br />\n" or "<br>\n") or "\n")
    elseif t == "linebreak" then
        lit(ctx, ctx.opts.xhtml and "<br />\n" or "<br>\n")
    elseif node.children then
        render_inlines(ctx, node.children)
    elseif node.value then
        lit(ctx, esc(node.value))
    end
end

--- Render a list of inline nodes.
---@param ctx MdRenderCtx
---@param nodes MdInlineNode[]?
render_inlines = function(ctx, nodes)
    for _, node in ipairs(nodes or {}) do
        render_inline(ctx, node)
    end
end

-- Forward declaration: containers recurse.
local render_block

--- Render a list of block nodes.
---@param ctx MdRenderCtx
---@param nodes MdNode[]?
---@param tight boolean?  inside a tight list, a paragraph renders without its `<p>` wrapper
local function render_blocks(ctx, nodes, tight)
    for _, node in ipairs(nodes or {}) do
        render_block(ctx, node, tight)
    end
end

--- Render one table row.
---@param ctx MdRenderCtx
---@param row MdTableRow
---@param align string[]
---@param cell_tag string
local function render_row(ctx, row, align, cell_tag)
    lit(ctx, "<tr" .. anchor(ctx, row) .. ">")
    cr(ctx)
    for i, cell in ipairs(row.cells) do
        local style = align[i] ~= "" and (' style="text-align:' .. align[i] .. '"') or ""
        lit(ctx, "<" .. cell_tag .. style .. ">")
        render_inlines(ctx, cell)
        lit(ctx, "</" .. cell_tag .. ">")
        cr(ctx)
    end
    lit(ctx, "</tr>")
    cr(ctx)
end

--- Render one block node.
---@param ctx MdRenderCtx
---@param node MdNode
---@param tight boolean?
render_block = function(ctx, node, tight)
    local t = node.type
    if t == "paragraph" then
        -- A tight list item's paragraph contributes its content and nothing else — that single rule
        -- is the whole difference between a tight and a loose list.
        if tight then
            render_inlines(ctx, node.inlines)
            return
        end
        cr(ctx)
        lit(ctx, "<p" .. anchor(ctx, node) .. ">")
        render_inlines(ctx, node.inlines)
        lit(ctx, "</p>")
        cr(ctx)
    elseif t == "heading" then
        local level = math.min(6, math.max(1, node.level + (ctx.opts.heading_shift or 0)))
        local id = ""
        if ctx.opts.heading_ids ~= false then
            id = (' id="%s"'):format(esc(heading_id(ctx, inline.to_text(node.inlines))))
        end
        cr(ctx)
        lit(ctx, ("<h%d%s%s>"):format(level, id, anchor(ctx, node)))
        render_inlines(ctx, node.inlines)
        lit(ctx, ("</h%d>"):format(level))
        cr(ctx)
    elseif t == "code_block" then
        -- The language class goes through the ATTRIBUTE escape, not the text one: an info string
        -- may hold a character reference, and `language-f&amp;ouml;&amp;ouml;` would be a class
        -- name no highlighter (and no `.language-mermaid` selector) could ever match.
        local lang = node.language and node.language ~= "" and (' class="language-' .. esc_attr(node.language) .. '"')
            or ""
        cr(ctx)
        lit(ctx, "<pre" .. anchor(ctx, node) .. "><code" .. lang .. ">")
        lit(ctx, esc(node.content))
        lit(ctx, "</code></pre>")
        cr(ctx)
    elseif t == "html_block" then
        cr(ctx)
        lit(ctx, node.content or "")
        cr(ctx)
    elseif t == "thematic_break" then
        cr(ctx)
        lit(ctx, "<hr" .. anchor(ctx, node) .. (ctx.opts.xhtml and " />" or ">"))
        cr(ctx)
    elseif t == "block_quote" then
        cr(ctx)
        lit(ctx, "<blockquote" .. anchor(ctx, node) .. ">")
        cr(ctx)
        render_blocks(ctx, node.children)
        cr(ctx)
        lit(ctx, "</blockquote>")
        cr(ctx)
    elseif t == "list" then
        local tag = node.ordered and "ol" or "ul"
        local start = (node.ordered and node.start and node.start ~= 1) and (' start="%d"'):format(node.start) or ""
        cr(ctx)
        lit(ctx, "<" .. tag .. anchor(ctx, node) .. start .. ">")
        cr(ctx)
        for _, item in ipairs(node.children) do
            render_block(ctx, item, node.tight ~= false)
        end
        cr(ctx)
        lit(ctx, "</" .. tag .. ">")
        cr(ctx)
    elseif t == "item" then
        local class = node.task and ("task-list-item task-list-item-" .. node.task) or nil
        lit(ctx, "<li" .. anchor(ctx, node, class) .. ">")
        if node.task then
            lit(
                ctx,
                ('<input type="checkbox" disabled%s%s> '):format(
                    node.task == "checked" and " checked" or "",
                    ctx.opts.xhtml and " /" or ""
                )
            )
        end
        render_blocks(ctx, node.children, tight)
        lit(ctx, "</li>")
        cr(ctx)
    elseif t == "table" then
        local align = node.align or {}
        cr(ctx)
        lit(ctx, "<table" .. anchor(ctx, node) .. ">")
        cr(ctx)
        lit(ctx, "<thead>")
        cr(ctx)
        render_row(ctx, node.head, align, "th")
        lit(ctx, "</thead>")
        cr(ctx)
        if #node.rows > 0 then
            lit(ctx, "<tbody>")
            cr(ctx)
            for _, row in ipairs(node.rows) do
                render_row(ctx, row, align, "td")
            end
            lit(ctx, "</tbody>")
            cr(ctx)
        end
        lit(ctx, "</table>")
        cr(ctx)
    elseif t == "footnote_def" then
        -- A definition produces nothing where it sits: it is collected and rendered ONCE, as the
        -- ordered footnote list at the document end (render_footnotes), and only if referenced.
        return
    end
end

--- Render a set of block nodes to a STRING using the live ctx (so heading-id and footnote counters
--- stay shared), then restore the ctx's own buffer. Used for a footnote definition's body, which is
--- assembled separately so the back-link can be spliced into its last paragraph.
---@param ctx MdRenderCtx
---@param nodes MdNode[]?
---@return string
local function render_to_string(ctx, nodes)
    local save_buf, save_nl = ctx.buf, ctx.nl
    ctx.buf, ctx.nl = {}, true
    render_blocks(ctx, nodes)
    local out = table.concat(ctx.buf)
    ctx.buf, ctx.nl = save_buf, save_nl
    return out
end

--- The footnote list at the document end: every REFERENCED definition, in reference order, each an
--- `<li id="fn-N">` whose text ends with a back-link to every reference that pointed at it. Modelled
--- on GitHub's output (`<section class="footnotes">` + an `<ol>`). Unreferenced definitions are
--- dropped (they never entered `fn_order`), matching GitHub.
---@param ctx MdRenderCtx
local function render_footnotes(ctx)
    if #ctx.fn_order == 0 then
        return
    end
    cr(ctx)
    lit(ctx, '<section class="footnotes" data-footnotes>')
    cr(ctx)
    lit(ctx, '<h2 class="sr-only" id="footnote-label">Footnotes</h2>')
    cr(ctx)
    lit(ctx, "<ol>")
    cr(ctx)
    for _, key in ipairs(ctx.fn_order) do
        local n = ctx.fn_number[key]
        local def = ctx.fn_defs[key]
        local body = render_to_string(ctx, def and def.children)
        -- One back-link per reference: `↩` for the first, `↩2`, `↩3`, … for repeats.
        local backrefs = {}
        for k = 1, math.max(1, ctx.fn_refs[key] or 1) do
            local refid = (k == 1) and ("fnref-" .. n) or ("fnref-" .. n .. "-" .. k)
            local sup = (k > 1) and ("<sup>" .. k .. "</sup>") or ""
            backrefs[#backrefs + 1] = (' <a href="#%s" data-footnote-backref class="data-footnote-backref" aria-label="Back to reference %d">↩%s</a>'):format(
                refid,
                n,
                sup
            )
        end
        local back = table.concat(backrefs)
        -- GitHub puts the back-link INSIDE the note's last paragraph; do the same when the body ends
        -- in a `</p>`, else append it after the block content. `%` is escaped for gsub's replacement.
        if body:find("</p>%s*$") then
            body = body:gsub("</p>(%s*)$", (back:gsub("%%", "%%%%")) .. "</p>%1", 1)
        else
            body = body .. back
        end
        lit(ctx, ('<li id="fn-%d">'):format(n))
        lit(ctx, body)
        lit(ctx, "</li>")
        cr(ctx)
    end
    lit(ctx, "</ol>")
    cr(ctx)
    lit(ctx, "</section>")
    cr(ctx)
end

--- Render a parsed markdown document to an HTML fragment (no `<html>`/`<body>` — the caller owns
--- the page shell).
---@param doc MdDocument
---@param opts MdHtmlOptions?
---@return string html
function M.render(doc, opts)
    ---@type MdRenderCtx
    local ctx = {
        buf = {},
        nl = true,
        opts = opts or {},
        ids = {},
        fn_defs = doc.footnotes or {},
        fn_number = {},
        fn_order = {},
        fn_refs = {},
    }
    render_blocks(ctx, doc.children)
    if ctx.opts.footnotes ~= false then
        render_footnotes(ctx)
    end
    return table.concat(ctx.buf)
end

return M
