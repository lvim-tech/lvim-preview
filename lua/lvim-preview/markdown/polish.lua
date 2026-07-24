-- lvim-preview.markdown.polish: the three OPTIONAL passes that run over an already-parsed inline
-- tree — typographic replacement, smart quotes, and bare-URL autolinking.
--
-- They live apart from the parser because none of them is CommonMark. Every one of them changes
-- what the author literally wrote (`--` becomes an en dash, `"x"` becomes curly quotes, a bare URL
-- becomes a link), so each is a separate switch and each runs as a pass over the finished tree
-- rather than as a rule inside the scanner. That is also how the browser renderer this replaces was
-- built, and matching it is the point: without these, every apostrophe on the page would change
-- shape the day the renderer was swapped.
--
-- ── one deliberate improvement over the previous renderer ─────────────────────────────────────
-- The old browser pipeline linkified FUZZILY: any word with a known-looking TLD became a link, even
-- with no scheme. Measured against this ecosystem's own documentation that rule produced 9 wrong
-- links and 2 right ones — `setup.py`, `noxfile.py`, `manage.py` and `CLAUDE.md` were all turned
-- into `http://…` anchors. So autolinking here requires an EXPLICIT scheme, a `www.` prefix, or an
-- email address, and nothing else. It is the one place this renderer knowingly does not reproduce
-- the old output, and it is a bug fix rather than a gap.
--
-- Pure Lua, pure string work — callable from the libuv HTTP callback.
--
---@module "lvim-preview.markdown.polish"

local M = {}

-- ── typographic replacement ───────────────────────────────────────────────

-- The `(c)`-style abbreviations, case-insensitively.
local ABBR = { c = "©", r = "®", tm = "™" }

--- Whether a character is whitespace or the (virtual) edge of the text.
---@param c string
---@return boolean
local function edge_space(c)
    return c == "" or c == " " or c == "\t" or c == "\n"
end

--- Replace runs of `-` with the dash they stand for: exactly three become an em dash, exactly two
--- an en dash — and only when the characters on BOTH sides are the same kind (both whitespace or
--- both not), which is what keeps a `--flag` in prose from turning into `–flag`.
---@param s string
---@return string
local function dashes(s)
    if not s:find("%-%-") then
        return s
    end
    local out, i, n = {}, 1, #s
    while i <= n do
        local run_end = s:match("^%-+()", i)
        if run_end then
            local len = run_end - i
            local before = i > 1 and s:sub(i - 1, i - 1) or ""
            local after = s:sub(run_end, run_end)
            if len == 3 then
                out[#out + 1] = "—"
            elseif len == 2 and (edge_space(before) == edge_space(after)) then
                out[#out + 1] = "–"
            else
                out[#out + 1] = s:sub(i, run_end - 1)
            end
            i = run_end
        else
            local nxt = s:find("%-", i) or (n + 1)
            out[#out + 1] = s:sub(i, nxt - 1)
            i = nxt
        end
    end
    return table.concat(out)
end

--- Apply every typographic replacement to one text run.
---@param s string
---@return string
local function replace_text(s)
    s = s:gsub("%((%a+)%)", function(name)
        return ABBR[name:lower()]
    end)
    s = s:gsub("%+%-", "±")
    s = s:gsub("%.%.%.?%.*", function(run)
        return #run >= 2 and "…" or run
    end)
    -- `?…` and `!…` read badly; the previous renderer walks them back to `?..` / `!..`.
    s = s:gsub("([%?!])…", "%1..")
    s = s:gsub("%?%?%?%?+", "???"):gsub("!!!!+", "!!!")
    s = s:gsub(",,+", ",")
    return dashes(s)
end

-- ── smart quotes ──────────────────────────────────────────────────────────

local QUOTES = { open_double = "“", close_double = "”", open_single = "‘", close_single = "’" }

--- ASCII punctuation, for the flanking test.
---@param c string
---@return boolean
local function is_punct(c)
    return c ~= "" and c:match("^[!-/:-@%[-`{-~]") ~= nil
end

--- The first (`dir = 1`) or last (`dir = -1`) character a node contributes, looking THROUGH
--- containers into their children.
---
--- Looking through matters: `**lvim-common**'s` puts the apostrophe right after a `strong` node, and
--- an implementation that treats a container edge as whitespace decides that quote can only OPEN —
--- leaving a straight `'` in the middle of a sentence.
---@param node MdInlineNode
---@param dir integer
---@return string?
local function edge_char(node, dir)
    if node.type == "softbreak" or node.type == "linebreak" then
        return " "
    end
    local text = node.value
    if text and text ~= "" then
        return dir < 0 and text:sub(-1) or text:sub(1, 1)
    end
    local kids = node.children
    if kids and #kids > 0 then
        local from, to = (dir < 0) and #kids or 1, (dir < 0) and 1 or #kids
        for i = from, to, dir do
            local c = edge_char(kids[i], dir)
            if c then
                return c
            end
        end
    end
    return nil
end

--- The character just before / just after a node, from whichever neighbour actually has one.
---@param nodes MdInlineNode[]
---@param index integer
---@param dir integer  -1 for the character before, 1 for the character after
---@return string
local function neighbour_char(nodes, index, dir)
    local i = index + dir
    while nodes[i] do
        local c = edge_char(nodes[i], dir)
        if c then
            return c
        end
        i = i + dir
    end
    return " "
end

--- Turn straight quotes into curly ones over one sibling run.
---
--- Follows the same open/close flanking test the previous renderer used: a quote opens when what
--- follows is not whitespace, closes when what precedes is not whitespace, and an unmatched `'`
--- that can only close becomes an apostrophe — which is the case that accounts for almost every
--- substitution in real prose.
---@param nodes MdInlineNode[]
local function smart_quotes(nodes)
    ---@type { index: integer, pos: integer, single: boolean }[]
    local stack = {}
    for index, node in ipairs(nodes) do
        if node.type == "text" and not node.no_quotes then
            local pos = 1
            while true do
                local at = node.value:find("['\"]", pos)
                if not at then
                    break
                end
                local single = node.value:sub(at, at) == "'"
                local before = at > 1 and node.value:sub(at - 1, at - 1) or neighbour_char(nodes, index, -1)
                local after = at < #node.value and node.value:sub(at + 1, at + 1) or neighbour_char(nodes, index, 1)

                local can_open, can_close = true, true
                if edge_space(after) then
                    can_open = false
                elseif is_punct(after) and not (edge_space(before) or is_punct(before)) then
                    can_open = false
                end
                if edge_space(before) then
                    can_close = false
                elseif is_punct(before) and not (edge_space(after) or is_punct(after)) then
                    can_close = false
                end
                -- `9"` is an inch mark, not a quote of any kind.
                if not single and after == '"' and before:match("%d") then
                    can_open, can_close = false, false
                end
                if can_open and can_close then
                    can_open, can_close = is_punct(before), is_punct(after)
                end

                local replaced = nil
                if can_close then
                    for j = #stack, 1, -1 do
                        if stack[j].single == single then
                            local open_q = single and QUOTES.open_single or QUOTES.open_double
                            local close_q = single and QUOTES.close_single or QUOTES.close_double
                            local opener = nodes[stack[j].index]
                            -- Replace the CLOSER first: rewriting the opener would shift `at` when
                            -- both quotes live in the same text node.
                            node.value = node.value:sub(1, at - 1) .. close_q .. node.value:sub(at + 1)
                            opener.value = opener.value:sub(1, stack[j].pos - 1)
                                .. open_q
                                .. opener.value:sub(stack[j].pos + 1)
                            replaced = at + #close_q
                            for k = #stack, j, -1 do
                                stack[k] = nil
                            end
                            break
                        end
                    end
                end
                if replaced then
                    pos = replaced
                elseif can_open then
                    stack[#stack + 1] = { index = index, pos = at, single = single }
                    pos = at + 1
                else
                    if single and can_close then
                        node.value = node.value:sub(1, at - 1) .. QUOTES.close_single .. node.value:sub(at + 1)
                        pos = at + #QUOTES.close_single
                    elseif single and not can_open then
                        node.value = node.value:sub(1, at - 1) .. QUOTES.close_single .. node.value:sub(at + 1)
                        pos = at + #QUOTES.close_single
                    else
                        pos = at + 1
                    end
                end
            end
        end
    end
end

-- ── autolinking bare URLs ─────────────────────────────────────────────────

-- Trailing characters that belong to the sentence, not to the URL.
local TRAILING = { ["."] = true, [","] = true, [";"] = true, [":"] = true, ["!"] = true, ["?"] = true }

--- Trim the punctuation a URL picked up from the sentence around it, closing `)` included when it
--- is not balanced by a `(` inside the URL.
---@param url string
---@return string
local function trim_url(url)
    while #url > 0 do
        local last = url:sub(-1)
        if TRAILING[last] or last == "'" or last == '"' then
            url = url:sub(1, -2)
        elseif last == ")" then
            local _, opens = url:gsub("%(", "")
            local _, closes = url:gsub("%)", "")
            if closes > opens then
                url = url:sub(1, -2)
            else
                break
            end
        else
            break
        end
    end
    return url
end

--- Find the next bare URL or email in `s` at or after `from`.
---@param s string
---@param from integer
---@return integer? at, integer? stop, string? text, string? dest
local function find_autolink(s, from)
    local at, stop = s:find("%a[%w%+%.%-]*://[^%s<>]+", from)
    if not at then
        at, stop = s:find("www%.[%w%-]+%.[^%s<>]+", from)
    end
    if at then
        -- Only at a word boundary: `see_http://x` is not a link.
        local before = at > 1 and s:sub(at - 1, at - 1) or ""
        if before:match("[%w@]") then
            return find_autolink(s, at + 1)
        end
        local text = trim_url(s:sub(at, stop))
        local dest = text:sub(1, 4) == "www." and ("http://" .. text) or text
        return at, at + #text - 1, text, dest
    end
    at, stop = s:find("[%w%._%+%-]+@[%w%-]+%.[%w%.%-]*%w", from)
    if at then
        local before = at > 1 and s:sub(at - 1, at - 1) or ""
        if before:match("[%w@%.]") then
            return find_autolink(s, stop + 1)
        end
        local text = s:sub(at, stop)
        return at, stop, text, "mailto:" .. text
    end
    return nil
end

--- Replace bare URLs and email addresses in a sibling run with link nodes.
---@param nodes MdInlineNode[]
---@return MdInlineNode[]
local function linkify(nodes)
    local out = {}
    for _, node in ipairs(nodes) do
        if node.type ~= "text" then
            out[#out + 1] = node
        else
            local s, pos = node.value or "", 1
            local made = false
            while true do
                local at, stop, text, dest = find_autolink(s, pos)
                if not (at and stop) then
                    break
                end
                made = true
                if at > pos then
                    out[#out + 1] = { type = "text", value = s:sub(pos, at - 1) }
                end
                out[#out + 1] = {
                    type = "link",
                    dest = dest,
                    autolink = true,
                    children = { { type = "text", value = text, no_quotes = true } },
                }
                pos = stop + 1
            end
            if not made then
                out[#out + 1] = node
            elseif pos <= #s then
                out[#out + 1] = { type = "text", value = s:sub(pos) }
            end
        end
    end
    return out
end

-- ── the pass ──────────────────────────────────────────────────────────────

---@class MdPolishOptions
---@field typographer boolean?  `(c)` → ©, `--` → –, `...` → …, straight quotes → curly (default true)
---@field linkify     boolean?  turn bare `https://…`, `www.…` and email addresses into links (default true)

--- Run the enabled passes over an inline node array, in place where possible.
---
--- Nodes inside a `link` are linkified no further (a link may not nest) and an AUTOLINK's own text
--- is left alone by the typographic passes, exactly as the previous renderer did — otherwise a URL
--- containing `--` or an apostrophe would be rewritten and stop matching its own href.
---@param nodes MdInlineNode[]
---@param opts MdPolishOptions
---@return MdInlineNode[]
function M.run(nodes, opts)
    if opts.linkify ~= false then
        nodes = linkify(nodes)
    end
    if opts.typographer ~= false then
        for _, node in ipairs(nodes) do
            if node.type == "text" and not node.no_quotes then
                node.value = replace_text(node.value)
            end
        end
        smart_quotes(nodes)
    end
    for _, node in ipairs(nodes) do
        if node.children and not node.autolink then
            node.children = M.run(
                node.children,
                node.type == "link" and { linkify = false, typographer = opts.typographer } or opts
            )
        end
    end
    return nodes
end

return M
