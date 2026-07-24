-- lvim-preview.markdown.inline: the INLINE (span-level) CommonMark scanner — everything inside one
-- paragraph, heading, table cell or list item: emphasis, links, images, code spans, autolinks, raw
-- HTML, entities, backslash escapes and line breaks.
--
-- ── why this is not a regex sweep ─────────────────────────────────────────────────────────────
-- CommonMark's emphasis and link rules are NOT expressible as "find the next marker". `*foo**bar**`
-- , `**foo*bar***`, `a_b_c`, `[a [b] c](url)` and `[foo][bar]` all resolve by rules that depend on
-- what came before AND after a marker. The spec therefore specifies an ALGORITHM, and this module
-- implements that algorithm rather than approximating it:
--
--   * a DELIMITER STACK of `*` / `_` / `~` runs, each classified left-flanking / right-flanking from
--     the Unicode class of the characters on either side, resolved at the end of the scan by the
--     spec's `process emphasis` procedure (including its "rule of three" and the `openers_bottom`
--     cut-off that keeps pathological input linear rather than quadratic);
--   * a BRACKET STACK for `[` / `![`, resolved by the spec's `look for link or image` procedure,
--     which is what makes a link inside a link impossible while an image inside a link is fine.
--
-- Nodes are built as a DOUBLY-LINKED LIST while scanning, exactly like the reference implementation,
-- because forming an emphasis or a link means MOVING a run of already-emitted nodes inside a new
-- parent. With an array, every delimiter's recorded position would be invalidated by that splice;
-- with links, the positions stay valid because nothing is re-indexed. `M.parse` flattens the list
-- into the plain `children` arrays the rest of the tree uses, so no consumer ever sees the links.
--
-- ── deliberate divergences (all visible-output-neutral, all measured) ─────────────────────────
--   * NAMED entities (`&nbsp;`, `&ouml;`) are passed through VERBATIM instead of being decoded to
--     their character. The browser decodes them itself, so the rendered page is identical; only the
--     HTML source string differs from the spec's. Numeric references ARE decoded, because the spec
--     also requires `&#0;` → U+FFFD and browsers disagree about that one.
--   * "Unicode punctuation" is ASCII punctuation plus the common non-ASCII punctuation/symbol
--     blocks (Latin-1, General Punctuation, arrows/math/misc symbols, CJK and fullwidth forms)
--     rather than the full Unicode general categories, which would need a property table.
--
-- Pure Lua, pure string work: no vim.api / vim.fn, so it is callable from the libuv HTTP callback
-- and portable out of this plugin (see `lvim-preview.markdown`).
--
---@module "lvim-preview.markdown.inline"

local M = {}

-- ── character classes ─────────────────────────────────────────────────────

--- ASCII punctuation, which is exactly the set a backslash may escape.
---@type table<string, boolean>
local ASCII_PUNCT = {}
for ch in ("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"):gmatch(".") do
    ASCII_PUNCT[ch] = true
end

-- Characters that end a plain-text run and are dispatched to a scanner.
local SPECIAL = {
    ["\n"] = true,
    ["`"] = true,
    ["\\"] = true,
    ["*"] = true,
    ["_"] = true,
    ["~"] = true,
    ["["] = true,
    ["]"] = true,
    ["!"] = true,
    ["<"] = true,
    ["&"] = true,
}

--- Decode the UTF-8 codepoint starting at byte `i`.
---
--- Malformed bytes decode as themselves, which keeps a file with a broken encoding rendering
--- instead of erroring — the same "never reject input" rule the block parser follows.
---@param s string
---@param i integer
---@return integer codepoint, integer length
local function cp_at(s, i)
    local b = s:byte(i)
    if not b then
        return 0, 1
    end
    if b < 0x80 then
        return b, 1
    elseif b < 0xE0 then
        local b2 = s:byte(i + 1) or 0
        return (b % 0x20) * 0x40 + (b2 % 0x40), 2
    elseif b < 0xF0 then
        local b2, b3 = s:byte(i + 1) or 0, s:byte(i + 2) or 0
        return (b % 0x10) * 0x1000 + (b2 % 0x40) * 0x40 + (b3 % 0x40), 3
    end
    local b2, b3, b4 = s:byte(i + 1) or 0, s:byte(i + 2) or 0, s:byte(i + 3) or 0
    return (b % 0x08) * 0x40000 + (b2 % 0x40) * 0x1000 + (b3 % 0x40) * 0x40 + (b4 % 0x40), 4
end

--- The codepoint ENDING at byte `i - 1` (the character before position `i`), and its start byte.
---@param s string
---@param i integer
---@return integer codepoint, integer start
local function cp_before(s, i)
    local j = i - 1
    if j < 1 then
        return 0, 1
    end
    -- Walk back over continuation bytes (10xxxxxx) to the lead byte.
    while j > 1 and s:byte(j) >= 0x80 and s:byte(j) < 0xC0 do
        j = j - 1
    end
    local cp = cp_at(s, j)
    return cp, j
end

--- Encode a codepoint as UTF-8 (for numeric character references).
---@param cp integer
---@return string
local function utf8_char(cp)
    if cp <= 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then
        return "\239\191\189" -- U+FFFD, per the spec's rule for invalid code points
    end
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return string.char(
        0xF0 + math.floor(cp / 0x40000),
        0x80 + math.floor(cp / 0x1000) % 0x40,
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40
    )
end
M.utf8_char = utf8_char

--- Unicode whitespace, as the flanking rules define it.
---@param cp integer
---@return boolean
local function is_space_cp(cp)
    return cp == 0x20
        or cp == 0x09
        or cp == 0x0A
        or cp == 0x0B
        or cp == 0x0C
        or cp == 0x0D
        or cp == 0xA0
        or (cp >= 0x2000 and cp <= 0x200A)
        or cp == 0x2028
        or cp == 0x2029
        or cp == 0x202F
        or cp == 0x205F
        or cp == 0x3000
end

-- Non-ASCII ranges counted as punctuation/symbol by the flanking rules. Approximates the Unicode
-- P and S general categories with the blocks that actually appear next to emphasis in prose.
local PUNCT_RANGES = {
    { 0xA1, 0xA9 },
    { 0xAB, 0xAC },
    { 0xAE, 0xB1 },
    { 0xB4, 0xB4 },
    { 0xB6, 0xB8 },
    { 0xBB, 0xBF },
    { 0xD7, 0xD7 },
    { 0xF7, 0xF7 },
    { 0x2010, 0x2027 },
    { 0x2030, 0x205E },
    { 0x20A0, 0x20BF },
    { 0x2190, 0x2BFF },
    { 0x2E00, 0x2E7F },
    { 0x3001, 0x303F },
    { 0xFE10, 0xFE19 },
    { 0xFE30, 0xFE6B },
    { 0xFF01, 0xFF0F },
    { 0xFF1A, 0xFF20 },
    { 0xFF3B, 0xFF40 },
    { 0xFF5B, 0xFF65 },
}

--- Unicode punctuation (or symbol), as the flanking rules define it.
---@param cp integer
---@return boolean
local function is_punct_cp(cp)
    if cp < 0x80 then
        return cp > 0x20 and ASCII_PUNCT[string.char(cp)] == true
    end
    for _, r in ipairs(PUNCT_RANGES) do
        if cp >= r[1] and cp <= r[2] then
            return true
        end
    end
    return false
end

-- ── the inline node list ──────────────────────────────────────────────────

---@class MdInlineNode
---@field type     string           text | raw | code | emph | strong | strike | link | image | softbreak | linebreak
---@field value    string?          text / raw / code: its literal content
---@field dest     string?          link / image: the destination, already unescaped
---@field title    string?          link / image: its title, already unescaped
---@field autolink boolean?         link: written as `<url>` or found by the linkify pass
---@field no_quotes boolean?        text: a URL's own text — never touched by the typographic passes
---@field children MdInlineNode[]?  container nodes: their children (after flattening)
---@field first    MdInlineNode?    internal: children head while scanning
---@field last     MdInlineNode?    internal: children tail while scanning
---@field prev     MdInlineNode?    internal: previous sibling while scanning
---@field next     MdInlineNode?    internal: next sibling while scanning
---@field parent   MdInlineNode?    internal: owner while scanning

--- Append `node` as the last child of `parent`.
---@param parent MdInlineNode
---@param node MdInlineNode
local function append(parent, node)
    node.parent = parent
    node.prev = parent.last
    node.next = nil
    if parent.last then
        parent.last.next = node
    else
        parent.first = node
    end
    parent.last = node
end

--- Insert `node` immediately after `ref`, in `ref`'s parent.
---@param ref MdInlineNode
---@param node MdInlineNode
local function insert_after(ref, node)
    local parent = ref.parent
    node.parent = parent
    node.prev = ref
    node.next = ref.next
    if ref.next then
        ref.next.prev = node
    elseif parent then
        parent.last = node
    end
    ref.next = node
end

--- Detach `node` from its siblings and parent.
---@param node MdInlineNode
local function unlink(node)
    local parent = node.parent
    if node.prev then
        node.prev.next = node.next
    elseif parent then
        parent.first = node.next
    end
    if node.next then
        node.next.prev = node.prev
    elseif parent then
        parent.last = node.prev
    end
    node.prev, node.next, node.parent = nil, nil, nil
end

--- Turn the scanning linked list into the plain `children` arrays the document tree uses. Runs once
--- per inline string, at the very end, so nothing downstream ever sees a `prev`/`next` pointer.
---@param parent MdInlineNode
---@return MdInlineNode[]
local function flatten(parent)
    local out = {}
    local node = parent.first
    while node do
        local nxt = node.next
        if node.first then
            node.children = flatten(node)
        end
        node.first, node.last, node.prev, node.next, node.parent = nil, nil, nil, nil, nil
        -- Merge adjacent text runs so a scan never emits two text nodes in a row.
        local prev = out[#out]
        if node.type == "text" and prev and prev.type == "text" then
            prev.value = prev.value .. node.value
        else
            out[#out + 1] = node
        end
        node = nxt
    end
    return out
end

-- ── escapes, entities, destinations ───────────────────────────────────────

--- Resolve a numeric character reference body (`#35`, `#X22`) to its character.
---@param body string
---@return string?
local function numeric_entity(body)
    local hex = body:match("^#[xX](%x%x?%x?%x?%x?%x?)$")
    if hex then
        return utf8_char(tonumber(hex, 16))
    end
    local dec = body:match("^#(%d%d?%d?%d?%d?%d?%d?)$")
    if dec then
        return utf8_char(tonumber(dec, 10))
    end
    return nil
end

--- Whether `body` has the shape of a NAMED entity (`&body;`). Validity against the HTML5 name list
--- is deliberately not checked — see the module header: an unknown name renders identically whether
--- it is passed through or escaped.
---@param body string
---@return boolean
local function named_entity_shape(body)
    return body:match("^%a[%w]*$") ~= nil and #body <= 32
end

--- Apply backslash escapes and character references to a link destination or title.
---@param s string
---@return string
local function unescape(s)
    if not s:find("[\\&]") then
        return s
    end
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c == "\\" and ASCII_PUNCT[s:sub(i + 1, i + 1)] then
            out[#out + 1] = s:sub(i + 1, i + 1)
            i = i + 2
        elseif c == "&" then
            local body, after = s:match("^&([^&;\n]*);()", i)
            local decoded = body and (numeric_entity(body) or (named_entity_shape(body) and ("&" .. body .. ";")))
            if decoded then
                out[#out + 1] = decoded
                i = after
            else
                out[#out + 1] = c
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end
M.unescape = unescape

-- Alphabets whose lower-casing is a constant codepoint offset, which is all the case folding a
-- reference label can be given without a full Unicode case table. Special cases that CHANGE LENGTH
-- (`ẞ` folding to `SS`) are deliberately out of scope and documented as such.
local CASE_RANGES = {
    { 0xC0, 0xDE, 0x20, 0xD7 }, -- Latin-1 supplement, minus the multiplication sign
    { 0x391, 0x3AB, 0x20, 0x3A2 }, -- Greek, minus the reserved slot
    { 0x400, 0x40F, 0x50 }, -- Cyrillic supplement
    { 0x410, 0x42F, 0x20 }, -- Cyrillic
}

--- Lower-case one codepoint, as far as arithmetic case folding reaches.
---@param cp integer
---@return integer
local function lower_cp(cp)
    if cp >= 0x41 and cp <= 0x5A then
        return cp + 0x20
    end
    for _, r in ipairs(CASE_RANGES) do
        if cp >= r[1] and cp <= r[2] and cp ~= r[4] then
            return cp + r[3]
        end
    end
    return cp
end

--- Normalise a link reference label: strip, collapse internal whitespace, case-fold.
---
--- Returns nil for a label that is empty or over the spec's 999-character limit, which is how the
--- caller distinguishes "no usable label" from "a label that happens to be unknown".
---@param label string
---@return string?
local function normalize_label(label)
    if #label > 999 then
        return nil
    end
    local norm = label:gsub("^[ \t\n]+", ""):gsub("[ \t\n]+$", ""):gsub("[ \t\n]+", " ")
    if norm == "" then
        return nil
    end
    if not norm:find("[^\032-\126]") then
        return norm:lower()
    end
    local out, i = {}, 1
    while i <= #norm do
        local cp, len = cp_at(norm, i)
        out[#out + 1] = utf8_char(lower_cp(cp))
        i = i + len
    end
    return table.concat(out)
end
M.normalize_label = normalize_label

--- Read a link destination at `i` — either `<…>` or a bare run with balanced parentheses.
---@param s string
---@param i integer
---@return string? dest, integer? next_index
local function parse_destination(s, i)
    if s:sub(i, i) == "<" then
        local j = i + 1
        local buf = {}
        while j <= #s do
            local c = s:sub(j, j)
            if c == ">" then
                return unescape(table.concat(buf)), j + 1
            elseif c == "<" or c == "\n" then
                return nil
            elseif c == "\\" and ASCII_PUNCT[s:sub(j + 1, j + 1)] then
                buf[#buf + 1] = s:sub(j, j + 1)
                j = j + 2
            else
                buf[#buf + 1] = c
                j = j + 1
            end
        end
        return nil
    end
    local j, depth, buf = i, 0, {}
    while j <= #s do
        local c = s:sub(j, j)
        local b = s:byte(j)
        if c == "\\" and ASCII_PUNCT[s:sub(j + 1, j + 1)] then
            buf[#buf + 1] = s:sub(j, j + 1)
            j = j + 2
        elseif c == "(" then
            depth = depth + 1
            buf[#buf + 1] = c
            j = j + 1
        elseif c == ")" then
            if depth == 0 then
                break
            end
            depth = depth - 1
            buf[#buf + 1] = c
            j = j + 1
        elseif b <= 32 or b == 127 then
            break
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
    if depth ~= 0 then
        return nil
    end
    -- An EMPTY bare destination is only legal immediately before the closing `)` of an inline link
    -- (`[a]()`); everywhere else "nothing at all" means this is not a destination.
    if j == i and s:sub(j, j) ~= ")" then
        return nil
    end
    return unescape(table.concat(buf)), j
end
M.parse_destination = parse_destination

--- Read a link title at `i` — `"…"`, `'…'` or `(…)`.
---@param s string
---@param i integer
---@return string? title, integer? next_index
local function parse_title(s, i)
    local open = s:sub(i, i)
    local close = (open == "(" and ")") or ((open == '"' or open == "'") and open) or nil
    if not close then
        return nil
    end
    local j, buf = i + 1, {}
    while j <= #s do
        local c = s:sub(j, j)
        if c == "\\" and ASCII_PUNCT[s:sub(j + 1, j + 1)] then
            buf[#buf + 1] = s:sub(j, j + 1)
            j = j + 2
        elseif c == close then
            return unescape(table.concat(buf)), j + 1
        elseif open == "(" and c == "(" then
            return nil -- an unescaped `(` may not appear inside a `(…)` title
        else
            buf[#buf + 1] = c
            j = j + 1
        end
    end
    return nil
end
M.parse_title = parse_title

--- Match a link label `[…]` at `i`. An unescaped `[` inside ends the match, which is what keeps
--- `[a [b] c]` from being read as one label.
---@param s string
---@param i integer
---@return integer? next_index  the index after the closing `]`
local function parse_link_label(s, i)
    if s:sub(i, i) ~= "[" then
        return nil
    end
    local j = i + 1
    while j <= #s do
        local c = s:sub(j, j)
        if c == "\\" then
            j = j + 2
        elseif c == "]" then
            return (j - i <= 1001) and (j + 1) or nil
        elseif c == "[" then
            return nil
        else
            j = j + 1
        end
    end
    return nil
end
M.parse_link_label = parse_link_label

--- Skip spaces, tabs and at most one line ending — the whitespace allowed inside `(dest "title")`
--- and between the parts of a link reference definition.
---@param s string
---@param i integer
---@return integer next_index
local function skip_ws(s, i)
    local seen_nl = false
    while i <= #s do
        local c = s:sub(i, i)
        if c == "\n" then
            if seen_nl then
                break
            end
            seen_nl = true
            i = i + 1
        elseif c == " " or c == "\t" then
            i = i + 1
        else
            break
        end
    end
    return i
end
M.skip_ws = skip_ws

-- ── raw HTML ──────────────────────────────────────────────────────────────

--- Match an HTML attribute at `i`, returning the index after it.
---@param s string
---@param i integer
---@return integer?
local function match_attribute(s, i)
    local after_ws = s:match("^[ \t\n]+()", i)
    if not after_ws then
        return nil
    end
    local after_name = s:match("^[%a_:][%w_%.:%-]*()", after_ws)
    if not after_name then
        return nil
    end
    -- The value is optional; only commit to one when an `=` actually follows.
    local eq = s:match("^[ \t\n]*=[ \t\n]*()", after_name)
    if not eq then
        return after_name
    end
    local q = s:sub(eq, eq)
    if q == '"' or q == "'" then
        local close = s:find(q, eq + 1, true)
        return close and (close + 1) or nil
    end
    return s:match("^[^ \t\n\"'=<>`]+()", eq)
end

--- Match a raw HTML tag / comment / processing instruction / declaration / CDATA at `i`.
---@param s string
---@param i integer
---@return integer? next_index
local function match_html_tag(s, i)
    if s:sub(i, i) ~= "<" then
        return nil
    end
    local c = s:sub(i + 1, i + 1)
    if c == "!" then
        if s:sub(i + 2, i + 3) == "--" then
            -- `<!-->` and `<!--->` are comments in their own right (CommonMark 0.31).
            if s:sub(i, i + 4) == "<!-->" then
                return i + 5
            end
            if s:sub(i, i + 5) == "<!--->" then
                return i + 6
            end
            local close = s:find("-->", i + 4, true)
            if not close then
                return nil
            end
            local body = s:sub(i + 4, close - 1)
            if body:sub(1, 1) == ">" or body:sub(1, 2) == "->" or body:sub(-1) == "-" then
                return nil
            end
            return close + 3
        end
        if s:sub(i + 2, i + 8) == "[CDATA[" then
            local close = s:find("]]>", i + 9, true)
            return close and (close + 3) or nil
        end
        if s:sub(i + 2, i + 2):match("%a") then
            local close = s:find(">", i + 2, true)
            return close and (close + 1) or nil
        end
        return nil
    elseif c == "?" then
        local close = s:find("?>", i + 2, true)
        return close and (close + 2) or nil
    elseif c == "/" then
        local after = s:match("^%a[%w%-]*()", i + 2)
        if not after then
            return nil
        end
        after = s:match("^[ \t\n]*()", after) or after
        return s:sub(after, after) == ">" and (after + 1) or nil
    end
    local after = s:match("^%a[%w%-]*()", i + 1)
    if not after then
        return nil
    end
    while true do
        local nxt = match_attribute(s, after)
        if not nxt then
            break
        end
        after = nxt
    end
    after = s:match("^[ \t\n]*()", after) or after
    if s:sub(after, after) == "/" then
        after = after + 1
    end
    return s:sub(after, after) == ">" and (after + 1) or nil
end
M.match_html_tag = match_html_tag

--- Whether `s` is an email autolink body, per the HTML5 email pattern the spec quotes: a local part
--- of allowed characters, then one or more dot-separated labels of alphanumerics and hyphens, each
--- starting and ending alphanumeric and at most 63 characters long.
---@param s string
---@return boolean
local function is_email(s)
    local local_part, domain = s:match("^([^@]+)@(.+)$")
    if not local_part or local_part:match("[^%w%.!#%$%%&'%*%+/=%?%^_`{|}~%-]") then
        return false
    end
    for label in (domain .. "."):gmatch("([^%.]*)%.") do
        if label == "" or #label > 63 or label:match("[^%w%-]") or label:sub(1, 1) == "-" or label:sub(-1) == "-" then
            return false
        end
    end
    return true
end

-- ── the scanner ───────────────────────────────────────────────────────────

---@class MdInlineOptions
---@field refmap table<string, { dest: string, title: string? }>?  link reference definitions
---@field strike boolean?  parse `~~text~~` as a deletion (default true)

---@class MdInlineState
---@field s      string
---@field pos    integer
---@field delims table?   top of the delimiter stack
---@field brackets table? top of the bracket stack
---@field refmap table
---@field opts   MdInlineOptions

--- Classify a delimiter run of `cc` starting at `pos`, per the spec's flanking rules.
---@param st MdInlineState
---@param cc string
---@return integer count, boolean can_open, boolean can_close
local function scan_delims(st, cc)
    local s, start = st.s, st.pos
    local i = start
    while s:sub(i, i) == cc do
        i = i + 1
    end
    local count = i - start
    local before_cp = cp_before(s, start)
    local after_cp = cp_at(s, i)
    local before_ws = start == 1 or is_space_cp(before_cp)
    local after_ws = i > #s or is_space_cp(after_cp)
    local before_punct = not before_ws and start > 1 and is_punct_cp(before_cp)
    local after_punct = not after_ws and i <= #s and is_punct_cp(after_cp)

    local left_flanking = not after_ws and (not after_punct or before_ws or before_punct)
    local right_flanking = not before_ws and (not before_punct or after_ws or after_punct)

    local can_open, can_close
    if cc == "_" then
        -- Intraword `_` never opens or closes, which is what keeps `snake_case_names` intact.
        can_open = left_flanking and (not right_flanking or before_punct)
        can_close = right_flanking and (not left_flanking or after_punct)
    elseif cc == "~" then
        -- GFM deletions pair only as a matched `~~`; a lone `~` is literal text.
        can_open = left_flanking
        can_close = right_flanking
    else
        can_open = left_flanking
        can_close = right_flanking
    end
    return count, can_open, can_close
end

--- Push a delimiter run onto the stack and emit its literal text (which `process_emphasis` later
--- shortens or removes as pairs are consumed).
---@param st MdInlineState
---@param block MdInlineNode
---@param cc string
local function handle_delim(st, block, cc)
    local count, can_open, can_close = scan_delims(st, cc)
    local text = { type = "text", value = st.s:sub(st.pos, st.pos + count - 1) }
    append(block, text)
    st.pos = st.pos + count
    st.delims = {
        cc = cc,
        num = count,
        orig = count,
        node = text,
        prev = st.delims,
        next = nil,
        can_open = can_open,
        can_close = can_close,
    }
    if st.delims.prev then
        st.delims.prev.next = st.delims
    end
end

--- Drop a delimiter from the stack (its text node stays — only the pairing candidacy is gone).
---@param st MdInlineState
---@param d table
local function remove_delim(st, d)
    if d.prev then
        d.prev.next = d.next
    end
    if d.next then
        d.next.prev = d.prev
    else
        st.delims = d.prev
    end
end

--- The spec's `process emphasis` procedure over the delimiter stack above `bottom`.
---
--- `openers_bottom` is not an optimisation detail that can be skipped: without it a run like
--- `*a**b*c*d*…` re-scans the whole stack for every closer, which is the quadratic blow-up that
--- makes naive implementations hang on generated documents.
---@param st MdInlineState
---@param bottom table?
local function process_emphasis(st, bottom)
    local openers_bottom = {}

    -- Start at the first delimiter above `bottom`.
    local closer = st.delims
    while closer and closer.prev ~= bottom do
        closer = closer.prev
    end

    while closer do
        if not closer.can_close then
            closer = closer.next
        else
            local key = closer.cc .. (closer.can_open and "o" or "c") .. tostring(closer.orig % 3)
            local floor = openers_bottom[key] or bottom
            local opener = closer.prev
            local found = false
            while opener and opener ~= floor and opener ~= bottom do
                if opener.cc == closer.cc and opener.can_open then
                    -- Rule of three: `*` and `_` runs that both flank on the inside may only pair
                    -- when their combined length is not a multiple of three (unless both are).
                    local odd = (closer.can_open or opener.can_close)
                        and closer.orig % 3 ~= 0
                        and (opener.orig + closer.orig) % 3 == 0
                    -- A GFM deletion is ONLY the double form: a lone `~` never pairs.
                    local short_strike = closer.cc == "~" and (closer.num < 2 or opener.num < 2)
                    if not odd and not short_strike then
                        found = true
                        break
                    end
                end
                opener = opener.prev
            end
            local old_closer = closer

            if found and opener then
                local use = (closer.num >= 2 and opener.num >= 2) and 2 or 1
                local node = { type = (closer.cc == "~" and "strike") or (use == 1 and "emph" or "strong") }
                -- Move everything between the two delimiter text nodes into the new node.
                local tmp = opener.node.next
                while tmp and tmp ~= closer.node do
                    local nxt = tmp.next
                    unlink(tmp)
                    append(node, tmp)
                    tmp = nxt
                end
                insert_after(opener.node, node)

                -- Consume `use` characters from each side and drop every delimiter in between.
                opener.node.value = opener.node.value:sub(1, #opener.node.value - use)
                closer.node.value = closer.node.value:sub(1 + use)
                opener.num = opener.num - use
                closer.num = closer.num - use
                local d = opener.next
                while d and d ~= closer do
                    local nxt = d.next
                    remove_delim(st, d)
                    d = nxt
                end
                if opener.num == 0 then
                    unlink(opener.node)
                    remove_delim(st, opener)
                end
                if closer.num == 0 then
                    local nxt = closer.next
                    unlink(closer.node)
                    remove_delim(st, closer)
                    closer = nxt
                end
            else
                openers_bottom[key] = old_closer.prev
                if not old_closer.can_open then
                    remove_delim(st, old_closer)
                end
                closer = old_closer.next
            end
        end
    end

    -- Everything above `bottom` has had its chance; the leftovers stay as literal text.
    while st.delims and st.delims ~= bottom do
        remove_delim(st, st.delims)
    end
end

--- `\n` — a soft break, or a hard break when the line ended in two spaces.
---@param st MdInlineState
---@param block MdInlineNode
local function parse_newline(st, block)
    st.pos = st.pos + 1
    local last = block.last
    local hard = false
    if last and last.type == "text" then
        local trail = last.value:match("( *)$")
        hard = #trail >= 2
        if #trail > 0 then
            last.value = last.value:sub(1, #last.value - #trail)
        end
        if last.value == "" then
            unlink(last)
        end
    end
    append(block, { type = hard and "linebreak" or "softbreak" })
    -- Leading whitespace of the next line is not content.
    st.pos = st.s:match("^[ \t]*()", st.pos) or st.pos
end

--- `` ` `` — a code span, or the literal backtick run when nothing closes it.
---@param st MdInlineState
---@param block MdInlineNode
local function parse_backticks(st, block)
    local s = st.s
    local open_end = s:match("^`+()", st.pos)
    local n = open_end - st.pos
    local j = open_end
    while j <= #s do
        local at = s:find("`", j, true)
        if not at then
            break
        end
        local run_end = s:match("^`+()", at)
        if run_end - at == n then
            local body = s:sub(open_end, at - 1):gsub("\r?\n", " ")
            -- One space is stripped from each end when both are spaces and the body is not blank.
            if #body >= 2 and body:sub(1, 1) == " " and body:sub(-1) == " " and body:match("[^ ]") then
                body = body:sub(2, #body - 1)
            end
            append(block, { type = "code", value = body })
            st.pos = run_end
            return
        end
        j = run_end
    end
    append(block, { type = "text", value = s:sub(st.pos, open_end - 1) })
    st.pos = open_end
end

--- `\` — an escaped punctuation character, a hard break, or a literal backslash.
---@param st MdInlineState
---@param block MdInlineNode
local function parse_backslash(st, block)
    local nxt = st.s:sub(st.pos + 1, st.pos + 1)
    if nxt == "\n" then
        append(block, { type = "linebreak" })
        st.pos = st.pos + 2
        st.pos = st.s:match("^[ \t]*()", st.pos) or st.pos
    elseif ASCII_PUNCT[nxt] then
        append(block, { type = "text", value = nxt })
        st.pos = st.pos + 2
    else
        append(block, { type = "text", value = "\\" })
        st.pos = st.pos + 1
    end
end

--- `<` — an autolink, a raw HTML tag, or a literal `<`.
---@param st MdInlineState
---@param block MdInlineNode
local function parse_lt(st, block)
    local s = st.s
    local close = s:find(">", st.pos + 1, true)
    if close then
        local body = s:sub(st.pos + 1, close - 1)
        local scheme = body:match("^(%a[%w%+%.%-]*):")
        if scheme and #scheme >= 2 and #scheme <= 32 and not body:match("[%s<]") and not body:match("%c") then
            local link = { type = "link", dest = body, autolink = true }
            append(link, { type = "text", value = body, no_quotes = true })
            append(block, link)
            st.pos = close + 1
            return
        end
        if is_email(body) then
            local link = { type = "link", dest = "mailto:" .. body, autolink = true }
            append(link, { type = "text", value = body, no_quotes = true })
            append(block, link)
            st.pos = close + 1
            return
        end
    end
    local after = match_html_tag(s, st.pos)
    if after then
        append(block, { type = "raw", value = s:sub(st.pos, after - 1) })
        st.pos = after
        return
    end
    append(block, { type = "text", value = "<" })
    st.pos = st.pos + 1
end

--- `&` — a character reference, or a literal ampersand.
---@param st MdInlineState
---@param block MdInlineNode
local function parse_entity(st, block)
    local body, after = st.s:match("^&([^&;%s]*);()", st.pos)
    if body then
        local numeric = numeric_entity(body)
        if numeric then
            append(block, { type = "text", value = numeric })
            st.pos = after
            return
        end
        if named_entity_shape(body) then
            -- Passed through verbatim: the browser decodes it, so the page is identical.
            append(block, { type = "raw", value = "&" .. body .. ";" })
            st.pos = after
            return
        end
    end
    append(block, { type = "text", value = "&" })
    st.pos = st.pos + 1
end

--- `[` / `![` — push a bracket and emit its literal text.
---@param st MdInlineState
---@param block MdInlineNode
---@param image boolean
local function push_bracket(st, block, image)
    local text = { type = "text", value = image and "![" or "[" }
    append(block, text)
    if st.brackets then
        -- The enclosing bracket's own text now contains a bracket, so it can no longer be used as
        -- a shortcut / collapsed reference label.
        st.brackets.bracket_after = true
    end
    st.brackets = {
        node = text,
        prev = st.brackets,
        prevdelim = st.delims,
        index = st.pos,
        image = image,
        active = true,
    }
    st.pos = st.pos + (image and 2 or 1)
end

--- Look up a reference label in the document's definitions.
---@param st MdInlineState
---@param label string
---@return { dest: string, title: string? }?
local function lookup_ref(st, label)
    local key = normalize_label(label)
    return key and st.refmap[key] or nil
end

--- `]` — the spec's `look for link or image` procedure.
---@param st MdInlineState
---@param block MdInlineNode
local function parse_close_bracket(st, block)
    local s = st.s
    st.pos = st.pos + 1
    local opener = st.brackets
    if not opener then
        append(block, { type = "text", value = "]" })
        return
    end
    if not opener.active then
        st.brackets = opener.prev
        append(block, { type = "text", value = "]" })
        return
    end

    local start_pos = st.pos
    local dest, title, matched = nil, nil, false

    -- Inline link: `](dest "title")`.
    if s:sub(st.pos, st.pos) == "(" then
        local i = skip_ws(s, st.pos + 1)
        local d, after = parse_destination(s, i)
        if d ~= nil then
            ---@cast after integer
            i = skip_ws(s, after)
            -- A title must be separated from the destination by whitespace.
            if i > after or s:sub(i, i) == ")" then
                local t, after_t = parse_title(s, i)
                if t ~= nil then
                    ---@cast after_t integer
                    i = skip_ws(s, after_t)
                    title = t
                end
            end
            if s:sub(i, i) == ")" then
                dest, matched = d, true
                st.pos = i + 1
            end
        end
    end

    -- Reference link: `][label]`, `][]` or the shortcut `]`.
    if not matched then
        local label = nil
        local after = nil
        after = parse_link_label(s, st.pos)
        if after then
            label = s:sub(st.pos + 1, after - 2)
        end
        local text_label = s:sub(opener.index + (opener.image and 2 or 1), start_pos - 2)
        local ref = nil
        if label and label ~= "" then
            ref = lookup_ref(st, label)
        elseif not opener.bracket_after then
            -- Collapsed (`[foo][]`) and shortcut (`[foo]`) both key on the bracket's own text.
            ref = lookup_ref(st, text_label)
        end
        if ref then
            dest, title, matched = ref.dest, ref.title, true
            st.pos = (label and after) or (s:sub(st.pos, st.pos + 1) == "[]" and st.pos + 2) or st.pos
        end
    end

    if not matched then
        st.brackets = opener.prev
        st.pos = start_pos
        append(block, { type = "text", value = "]" })
        return
    end

    local node = { type = opener.image and "image" or "link", dest = dest, title = title }
    local tmp = opener.node.next
    while tmp do
        local nxt = tmp.next
        unlink(tmp)
        append(node, tmp)
        tmp = nxt
    end
    append(block, node)
    -- Emphasis inside the label resolves against the bracket's own delimiter floor, so a `*` that
    -- opened before the `[` can never pair with one inside it.
    process_emphasis(st, opener.prevdelim)
    unlink(opener.node)
    st.brackets = opener.prev
    if not opener.image then
        -- Links may not nest: every still-open `[` before this one is dead.
        local b = st.brackets
        while b do
            if not b.image then
                b.active = false
            end
            b = b.prev
        end
    end
end

--- Parse an inline string into a flat array of inline nodes.
---
--- Never fails and never drops input: any character no scanner claims becomes text, so an
--- unbalanced marker, a half-written link or an unterminated code span survives as the literal text
--- the author typed.
---@param s string
---@param opts MdInlineOptions?
---@return MdInlineNode[]
function M.parse(s, opts)
    opts = opts or {}
    ---@type MdInlineState
    local st = { s = s, pos = 1, delims = nil, brackets = nil, refmap = opts.refmap or {}, opts = opts }
    local block = { type = "root" }
    local n = #s

    while st.pos <= n do
        local c = s:sub(st.pos, st.pos)
        if c == "\n" then
            parse_newline(st, block)
        elseif c == "\\" then
            parse_backslash(st, block)
        elseif c == "`" then
            parse_backticks(st, block)
        elseif c == "*" or c == "_" then
            handle_delim(st, block, c)
        elseif c == "~" and opts.strike ~= false then
            handle_delim(st, block, c)
        elseif c == "[" then
            push_bracket(st, block, false)
        elseif c == "!" and s:sub(st.pos + 1, st.pos + 1) == "[" then
            push_bracket(st, block, true)
        elseif c == "]" then
            parse_close_bracket(st, block)
        elseif c == "<" then
            parse_lt(st, block)
        elseif c == "&" then
            parse_entity(st, block)
        else
            -- A run of ordinary characters, taken in one slice rather than character by character.
            local j = st.pos + 1
            while j <= n and not SPECIAL[s:sub(j, j)] do
                j = j + 1
            end
            append(block, { type = "text", value = s:sub(st.pos, j - 1) })
            st.pos = j
        end
        -- Every branch consumes at least one byte; this only fires on a scanner bug.
        if st.pos <= n and block.last == nil then
            st.pos = st.pos + 1
        end
    end

    process_emphasis(st, nil)
    return flatten(block)
end

--- Read a link reference definition (`[label]: dest "title"`) off the FRONT of `s`.
---
--- Lives here rather than in the block parser because a definition is made of inline pieces (a
--- label, a destination, a title) and reuses the very same readers as an inline link. The block
--- parser calls it while finalising a paragraph, which is what makes a definition invisible in the
--- output while still being usable by a `[foo]` that appeared EARLIER in the document.
---@param s string
---@param refmap table<string, { dest: string, title: string? }>  filled in place; first definition wins
---@return integer consumed  bytes taken off the front of `s`, or 0 when this is not a definition
function M.parse_reference(s, refmap)
    local after_label = parse_link_label(s, 1)
    if not after_label or s:sub(after_label, after_label) ~= ":" then
        return 0
    end
    local raw_label = s:sub(2, after_label - 2)
    local i = skip_ws(s, after_label + 1)
    local dest, after_dest = parse_destination(s, i)
    if dest == nil then
        return 0
    end
    ---@cast after_dest integer

    -- A title must be separated from the destination by whitespace AND be the last thing on its
    -- line; a "title" that is followed by other text means the definition simply has no title.
    local before_title = after_dest
    local title = nil
    local title_from = skip_ws(s, before_title)
    ---@type integer?
    local pos = title_from
    if title_from > before_title then
        local t, after_title = parse_title(s, title_from)
        if t ~= nil then
            ---@cast after_title integer
            local line_end = s:match("^[ \t]*\n()", after_title) or s:match("^[ \t]*()$", after_title)
            if line_end then
                title = t
                pos = line_end
            else
                pos = nil
            end
        else
            pos = nil
        end
    else
        pos = nil
    end
    if pos == nil then
        pos = s:match("^[ \t]*\n()", before_title) or s:match("^[ \t]*()$", before_title)
        if pos == nil then
            return 0
        end
    end

    local key = normalize_label(raw_label)
    if not key then
        return 0
    end
    -- First definition wins, which is what the spec says and what makes an accidental duplicate
    -- late in a document harmless.
    if not refmap[key] then
        refmap[key] = { dest = dest, title = title }
    end
    return pos - 1
end

--- Flatten inline nodes back to plain text (an image's `alt`, a heading's anchor id, the `<title>`).
---@param nodes MdInlineNode[]?
---@return string
function M.to_text(nodes)
    local parts = {}
    for _, node in ipairs(nodes or {}) do
        if node.type == "text" or node.type == "code" then
            parts[#parts + 1] = node.value
        elseif node.type == "softbreak" or node.type == "linebreak" then
            parts[#parts + 1] = "\n"
        elseif node.children then
            parts[#parts + 1] = M.to_text(node.children)
        end
    end
    return table.concat(parts)
end

return M
