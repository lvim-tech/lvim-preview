-- lvim-preview.org.inline: the INLINE (object-level) org scanner — everything that lives inside
-- one paragraph, heading title, table cell or list item: emphasis, links, code, LaTeX fragments,
-- timestamps, footnote references, targets, sub/superscripts and hard line breaks.
--
-- Separate from the block parser on purpose. The block level is line-regular and reads as a state
-- machine over lines; the inline level is a character scanner over a STRING that may contain
-- newlines (org emphasis is allowed to span a single line break, so a paragraph is scanned as one
-- joined string rather than line by line).
--
-- Emphasis follows org's own `org-emphasis-regexp-components` rather than a naive "find the next
-- marker": a marker only opens when the character BEFORE it is start-of-string or one of the PRE
-- set, and only closes when the character before the closing marker is not whitespace and the one
-- after it is end-of-string or in the POST set. Without those rules a bare `a * b * c`, a snake_
-- case identifier or a `5/3` fraction all turn into emphasis, which is the classic way a
-- hand-written org renderer becomes unusable on real documents.
--
-- Pure Lua and pure string work — no vim.api, no vim.fn — because this runs inside the libuv HTTP
-- callback as well as on the main thread, and because the whole `lvim-preview.org` tree is meant
-- to be lifted out into a shared home later (see lvim-preview.org's module header).
--
---@module "lvim-preview.org.inline"

local M = {}

-- Characters that may precede an opening emphasis marker (plus start-of-string). Mirrors org's
-- default `pre` component, with the unicode dashes spelled out as bytes we can test cheaply.
local PRE = {
    [" "] = true,
    ["\t"] = true,
    ["\n"] = true,
    ["-"] = true,
    ["("] = true,
    ["'"] = true,
    ['"'] = true,
    ["{"] = true,
    ["["] = true,
    [":"] = true,
}

-- Characters that may follow a closing emphasis marker (plus end-of-string). Org's `post`.
local POST = {
    [" "] = true,
    ["\t"] = true,
    ["\n"] = true,
    ["-"] = true,
    ["."] = true,
    [","] = true,
    [":"] = true,
    ["!"] = true,
    ["?"] = true,
    [";"] = true,
    ["'"] = true,
    ['"'] = true,
    [")"] = true,
    ["}"] = true,
    ["["] = true,
    ["]"] = true,
    ["\\"] = true,
}

-- Emphasis marker → node type. `=` and `~` are VERBATIM markers: their body is taken literally
-- and is never scanned again, which is what makes `=a *b* c=` show the asterisks.
local MARKERS = {
    ["*"] = "bold",
    ["/"] = "italic",
    ["_"] = "underline",
    ["+"] = "strike",
    ["="] = "verbatim",
    ["~"] = "code",
}
local LITERAL = { verbatim = true, code = true }

-- Link paths whose extension makes them an inline image rather than an anchor.
local IMAGE_EXT = {
    png = true,
    jpg = true,
    jpeg = true,
    gif = true,
    svg = true,
    webp = true,
    avif = true,
    bmp = true,
    ico = true,
}

--- Trim ASCII whitespace off both ends (own implementation — this module must not depend on
--- anything outside itself).
---@param s string
---@return string
local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

--- Append a text node, merging with the previous one so a scan never emits adjacent text runs.
---@param out table[]
---@param s string
local function push_text(out, s)
    if s == "" then
        return
    end
    local last = out[#out]
    if last and last.type == "text" then
        last.value = last.value .. s
    else
        out[#out + 1] = { type = "text", value = s }
    end
end

--- Whether a closing marker at `j` is legal: the body must not end in whitespace and the
--- character after the marker must be end-of-string or in POST.
---@param s string
---@param open integer  index of the opening marker
---@param j integer     index of the candidate closing marker
---@return boolean
local function closes_here(s, open, j)
    if j <= open + 1 then
        return false -- empty body: `**` is not bold
    end
    local before = s:sub(j - 1, j - 1)
    if before:match("%s") then
        return false
    end
    local after = s:sub(j + 1, j + 1)
    return after == "" or POST[after] == true
end

--- Try to read an emphasis run starting at `i`.
---@param s string
---@param i integer
---@return table? node, integer? next_index
local function try_emphasis(s, i)
    local c = s:sub(i, i)
    local kind = MARKERS[c]
    if not kind then
        return nil
    end
    local prev = i > 1 and s:sub(i - 1, i - 1) or ""
    if prev ~= "" and not PRE[prev] then
        return nil
    end
    local first = s:sub(i + 1, i + 1)
    if first == "" or first:match("%s") or first == c then
        return nil
    end
    -- Scan for a legal closing marker, allowing at most ONE newline in the body (org's `newline`
    -- component): emphasis may wrap a line, but it may not swallow a whole paragraph.
    local newlines = 0
    local j = i + 1
    while j <= #s do
        local ch = s:sub(j, j)
        if ch == "\n" then
            newlines = newlines + 1
            if newlines > 1 then
                return nil
            end
        elseif ch == c and closes_here(s, i, j) then
            local body = s:sub(i + 1, j - 1)
            if LITERAL[kind] then
                return { type = kind, value = body }, j + 1
            end
            return { type = kind, children = M.parse(body) }, j + 1
        end
        j = j + 1
    end
    return nil
end

--- Split a link target into its protocol and path. `file:` is stripped here rather than in the
--- renderer: a browser must never be handed a `file:` URL (it refuses it), and the remainder is a
--- path relative to the document, which is exactly what resolves against the served page.
---@param target string
---@return string path, string? protocol
local function split_target(target)
    local proto, rest = target:match("^(%a[%w%+%.%-]*):(.*)$")
    if proto and proto:lower() == "file" then
        return rest, "file"
    end
    if proto then
        return target, proto:lower()
    end
    return target, nil
end

--- Try to read `[[target]]` / `[[target][description]]`.
---
--- The description is scanned for the FIRST `]]` rather than for a balanced `]`, so a bracket
--- inside a description (`[[url][an [odd] name]]`) keeps the bracket instead of ending the link
--- early — the failure mode a naive `%[%[(.-)%]%[(.-)%]%]` pattern has.
---@param s string
---@param i integer
---@return table? node, integer? next_index
local function try_link(s, i)
    if s:sub(i, i + 1) ~= "[[" then
        return nil
    end
    local close = s:find("]]", i + 2, true)
    if not close then
        return nil
    end
    -- Walk further `]]` occurrences while the description still holds an unbalanced `[`.
    local inner = s:sub(i + 2, close - 1)
    while select(2, inner:gsub("%[", "")) > select(2, inner:gsub("%]", "")) do
        local nxt = s:find("]]", close + 1, true)
        if not nxt then
            break
        end
        close = nxt
        inner = s:sub(i + 2, close - 1)
    end
    local target, desc = inner:match("^(.-)%]%[(.*)$")
    if not target then
        target = inner
    end
    local path, protocol = split_target(target)
    local ext = path:match("%.([%w]+)$")
    local node = {
        type = "link",
        path = path,
        protocol = protocol,
        raw = target,
        image = desc == nil and ext ~= nil and IMAGE_EXT[ext:lower()] == true,
    }
    if desc and desc ~= "" then
        node.description = M.parse(desc)
    end
    return node, close + 2
end

--- Try to read a footnote reference: `[fn:label]`, `[fn:label:inline definition]` or the
--- anonymous `[fn::inline definition]`.
---@param s string
---@param i integer
---@return table? node, integer? next_index
local function try_footnote(s, i)
    if s:sub(i, i + 3) ~= "[fn:" then
        return nil
    end
    -- Balanced scan: an inline definition may itself contain brackets (a link, most often).
    local depth, j = 0, i
    while j <= #s do
        local ch = s:sub(j, j)
        if ch == "[" then
            depth = depth + 1
        elseif ch == "]" then
            depth = depth - 1
            if depth == 0 then
                break
            end
        end
        j = j + 1
    end
    if depth ~= 0 then
        return nil
    end
    local body = s:sub(i + 4, j - 1)
    local label, inline = body:match("^([%w_%-]*):(.*)$")
    if not label then
        label, inline = body, nil
    end
    local node = { type = "footnote_reference", label = label ~= "" and label or nil }
    if inline and inline ~= "" then
        node.inline = M.parse(inline)
    end
    return node, j + 1
end

-- Inline LaTeX delimiters, longest first so `$$` is tried before `$`.
local LATEX = {
    { "$$", "$$", true },
    { "\\[", "\\]", true },
    { "\\(", "\\)", false },
}

--- Try to read a LaTeX fragment. The node keeps its DELIMITERS: the browser-side KaTeX
--- auto-render pass scans for them, so a fragment stripped of `$…$` would be skipped entirely.
---@param s string
---@param i integer
---@return table? node, integer? next_index
local function try_latex(s, i)
    for _, d in ipairs(LATEX) do
        local open, close = d[1], d[2]
        if s:sub(i, i + #open - 1) == open then
            local at = s:find(close, i + #open, true)
            if at then
                return { type = "latex_fragment", value = s:sub(i, at + #close - 1), display = d[3] }, at + #close
            end
        end
    end
    if s:sub(i, i) == "$" then
        -- Single-dollar math: the closing `$` must not be preceded by whitespace and must not be
        -- followed by a digit, so prices ("$5 and $6") and shell snippets stay plain text.
        local prev = i > 1 and s:sub(i - 1, i - 1) or ""
        if prev ~= "" and not PRE[prev] then
            return nil
        end
        if s:sub(i + 1, i + 1):match("[%s$]") then
            return nil
        end
        local j = i + 1
        while j <= #s do
            local ch = s:sub(j, j)
            if ch == "\n" then
                return nil
            end
            if ch == "$" and not s:sub(j - 1, j - 1):match("%s") and not s:sub(j + 1, j + 1):match("%d") then
                return { type = "latex_fragment", value = s:sub(i, j), display = false }, j + 1
            end
            j = j + 1
        end
    end
    return nil
end

-- An org timestamp body: a date, an optional day name, an optional time or time range, and
-- optional repeater/delay cookies. Matched loosely on purpose — a timestamp is displayed, never
-- computed with, so a shape we do not recognise is better shown verbatim than dropped.
local TS_BODY = "^%d%d%d%d%-%d%d%-%d%d[^%]>\n]*$"

--- Try to read `<2026-07-24 Fri 10:00>` (active) or `[2026-07-24 Fri]` (inactive).
---@param s string
---@param i integer
---@return table? node, integer? next_index
local function try_timestamp(s, i)
    local open = s:sub(i, i)
    local close = open == "<" and ">" or (open == "[" and "]" or nil)
    if not close then
        return nil
    end
    local at = s:find(close, i + 1, true)
    if not at then
        return nil
    end
    local body = s:sub(i + 1, at - 1)
    if not body:match(TS_BODY) then
        return nil
    end
    return { type = "timestamp", value = body, active = open == "<" }, at + 1
end

--- Try to read a radio/dedicated target `<<name>>` (rendered as an anchor, never as text).
---@param s string
---@param i integer
---@return table? node, integer? next_index
local function try_target(s, i)
    if s:sub(i, i + 1) ~= "<<" then
        return nil
    end
    local at = s:find(">>", i + 2, true)
    if not at then
        return nil
    end
    return { type = "target", value = s:sub(i + 2, at - 1) }, at + 2
end

--- Try to read a BRACED sub/superscript (`x^{2}`, `a_{ij}`).
---
--- Only the braced form is supported, deliberately: org's bare `a_b` form turns every snake_case
--- word and every `H_2O`-shaped string in prose into a subscript, and there is no way for a
--- previewer to tell the two apart. Documented as unsupported rather than guessed.
---@param s string
---@param i integer
---@return table? node, integer? next_index
local function try_script(s, i)
    local c = s:sub(i, i)
    if (c ~= "^" and c ~= "_") or s:sub(i + 1, i + 1) ~= "{" then
        return nil
    end
    local depth, j = 0, i + 1
    while j <= #s do
        local ch = s:sub(j, j)
        if ch == "{" then
            depth = depth + 1
        elseif ch == "}" then
            depth = depth - 1
            if depth == 0 then
                break
            end
        elseif ch == "\n" then
            return nil
        end
        j = j + 1
    end
    if depth ~= 0 then
        return nil
    end
    return {
        type = c == "^" and "superscript" or "subscript",
        children = M.parse(s:sub(i + 2, j - 1)),
    },
        j + 1
end

--- Try to read a hard line break: a `\\` with nothing but whitespace after it on that line.
---@param s string
---@param i integer
---@return table? node, integer? next_index
local function try_break(s, i)
    if s:sub(i, i + 1) ~= "\\\\" then
        return nil
    end
    local rest = s:match("^([^\n]*)", i + 2)
    if rest and rest:match("^%s*$") then
        return { type = "line_break" }, i + 2 + #rest + 1
    end
    return nil
end

-- Scanners in priority order. Order matters: `[[` must be tried before `[fn:`-style bracket
-- scanning and before an inactive timestamp, `\\` before `\(`, and `^{`/`_{` before `_underline_`.
local SCANNERS = { try_break, try_latex, try_link, try_footnote, try_target, try_timestamp, try_script, try_emphasis }

--- Parse an inline string into object nodes.
---
--- Never fails and never drops input: any character no scanner claims becomes text, so an
--- unbalanced marker, a half-written link or an unknown construct survives the round trip as the
--- literal text the author typed.
---@param s string
---@return table[] nodes
function M.parse(s)
    local out = {}
    local i, n = 1, #s
    local plain_from = 1
    while i <= n do
        local matched = false
        for _, scan in ipairs(SCANNERS) do
            local node, nxt = scan(s, i)
            -- A scanner returns its next index with its node; `nxt or i + 1` keeps the loop
            -- advancing even if a future scanner ever returns a node without one.
            if node then
                push_text(out, s:sub(plain_from, i - 1))
                out[#out + 1] = node
                i = math.max(nxt or (i + 1), i + 1)
                plain_from = i
                matched = true
                break
            end
        end
        if not matched then
            i = i + 1
        end
    end
    push_text(out, s:sub(plain_from))
    return out
end

--- Flatten inline nodes back to their plain text (heading ids, `alt` text, the `<title>`).
---@param nodes table[]
---@return string
function M.to_text(nodes)
    local parts = {}
    for _, node in ipairs(nodes or {}) do
        if node.type == "text" or node.type == "code" or node.type == "verbatim" or node.type == "latex_fragment" then
            parts[#parts + 1] = node.value
        elseif node.type == "timestamp" then
            parts[#parts + 1] = node.value
        elseif node.type == "line_break" then
            parts[#parts + 1] = " "
        elseif node.children then
            parts[#parts + 1] = M.to_text(node.children)
        elseif node.type == "link" then
            parts[#parts + 1] = node.description and M.to_text(node.description) or node.path
        end
    end
    return table.concat(parts)
end

return M
