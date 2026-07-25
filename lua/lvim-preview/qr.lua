-- lvim-preview.qr: a self-contained QR-code encoder (byte mode, EC level M, versions 1..10) plus a
-- terminal renderer, used by `:LvimPreview qr` to put the preview URL on screen so a phone on the
-- LAN can open it without typing an IP. Pure Lua, no external tools — the ecosystem never shells out
-- to `qrencode`. The encoder was verified byte-for-byte against libqrencode (`qrencode -8 -l M`) for a
-- spread of URLs across versions 2..6: identical data, ECC and function-pattern modules; the mask is
-- chosen by the standard four-rule penalty, a valid free choice per the spec.
--
-- Rendering uses the upper-half-block glyph (▀): one character encodes TWO vertical modules — its
-- FOREGROUND paints the top module, its BACKGROUND the bottom. Four fixed black/white highlight
-- groups (never theme-derived: a scannable code needs true contrast regardless of the editor theme)
-- cover the four top/bottom dark/light combinations, and a 4-module light quiet zone frames it.
--
---@module "lvim-preview.qr"

local bit = require("bit")
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local lshift, rshift = bit.lshift, bit.rshift

local M = {}

-- ── GF(256) arithmetic (primitive polynomial 0x11d, generator 2) ───────────────────────
---@type integer[]
local EXP = {}
---@type integer[]
local LOG = {}
do
    local x = 1
    for i = 0, 255 do
        EXP[i] = x
        LOG[x] = i
        x = lshift(x, 1)
        if x >= 256 then
            x = bxor(x, 0x11d)
        end
    end
    for i = 256, 511 do
        EXP[i] = EXP[i - 255]
    end
end

--- GF(256) multiply.
---@param a integer
---@param b integer
---@return integer
local function gmul(a, b)
    if a == 0 or b == 0 then
        return 0
    end
    return EXP[(LOG[a] + LOG[b]) % 255]
end

--- Reed-Solomon generator polynomial of degree `n`, monic, coefficients high→low (index 1 = leading).
---@param n integer
---@return integer[]
local function rs_gen(n)
    local g = { 1 }
    for i = 0, n - 1 do
        local ng = {}
        for j = 1, #g + 1 do
            ng[j] = 0
        end
        for j = 1, #g do
            ng[j] = bxor(ng[j], g[j]) -- x · g (leading coefficient stays 1)
            ng[j + 1] = bxor(ng[j + 1], gmul(g[j], EXP[i])) -- α^i · g
        end
        g = ng
    end
    return g
end

--- The `n` Reed-Solomon EC codewords for `data`.
---@param data integer[]
---@param n integer
---@return integer[]
local function rs_ecc(data, n)
    local gen = rs_gen(n)
    local res = {}
    for i = 1, #data + n do
        res[i] = data[i] or 0
    end
    for i = 1, #data do
        local coef = res[i]
        if coef ~= 0 then
            for j = 1, #gen do
                res[i + j - 1] = bxor(res[i + j - 1], gmul(gen[j], coef))
            end
        end
    end
    local ecc = {}
    for i = 1, n do
        ecc[i] = res[#data + i]
    end
    return ecc
end

-- ── Per-version tables (EC level M) ────────────────────────────────────────────────────
---@class LvimPreviewQrVersion
---@field ec     integer            EC codewords per block
---@field groups integer[][]        { {blocks, datawords}, ... }

---@type table<integer, LvimPreviewQrVersion>
local VER = {
    [1] = { ec = 10, groups = { { 1, 16 } } },
    [2] = { ec = 16, groups = { { 1, 28 } } },
    [3] = { ec = 26, groups = { { 1, 44 } } },
    [4] = { ec = 18, groups = { { 2, 32 } } },
    [5] = { ec = 24, groups = { { 2, 43 } } },
    [6] = { ec = 16, groups = { { 4, 27 } } },
    [7] = { ec = 18, groups = { { 4, 31 } } },
    [8] = { ec = 22, groups = { { 2, 38 }, { 2, 39 } } },
    [9] = { ec = 22, groups = { { 3, 36 }, { 2, 37 } } },
    [10] = { ec = 26, groups = { { 4, 43 }, { 1, 44 } } },
}

--- Alignment-pattern centre coordinates per version.
---@type table<integer, integer[]>
local ALIGN = {
    [1] = {},
    [2] = { 6, 18 },
    [3] = { 6, 22 },
    [4] = { 6, 26 },
    [5] = { 6, 30 },
    [6] = { 6, 34 },
    [7] = { 6, 22, 38 },
    [8] = { 6, 24, 42 },
    [9] = { 6, 26, 46 },
    [10] = { 6, 28, 50 },
}

--- Version-information bit strings (v7+), MSB first (bit 17 … bit 0).
---@type table<integer, string>
local VERSION_INFO = {
    [7] = "000111110010010100",
    [8] = "001000010110111100",
    [9] = "001001101010011001",
    [10] = "001010010011010011",
}

---@param v integer
---@return integer
local function data_capacity(v)
    local cw = 0
    for _, g in ipairs(VER[v].groups) do
        cw = cw + g[1] * g[2]
    end
    return cw
end

-- ── Encoding ───────────────────────────────────────────────────────────────────────────
--- Smallest version (1..10) whose byte-mode capacity holds `len` bytes at EC level M.
---@param len integer
---@return integer?
local function pick_version(len)
    for v = 1, 10 do
        local count_bits = v <= 9 and 8 or 16
        if 4 + count_bits + 8 * len <= 8 * data_capacity(v) then
            return v
        end
    end
    return nil
end

--- Padded data-codeword bytes for `text` at version `v` (byte mode + terminator + 0xEC/0x11 pad).
---@param text string
---@param v integer
---@return integer[]
local function encode_data(text, v)
    local bits = {}
    local function put(value, n)
        for i = n - 1, 0, -1 do
            bits[#bits + 1] = band(rshift(value, i), 1)
        end
    end
    put(4, 4) -- byte mode
    put(#text, v <= 9 and 8 or 16)
    for i = 1, #text do
        put(text:byte(i), 8)
    end
    local cap_bits = 8 * data_capacity(v)
    for _ = 1, math.min(4, cap_bits - #bits) do
        bits[#bits + 1] = 0
    end
    while #bits % 8 ~= 0 do
        bits[#bits + 1] = 0
    end
    local pads = { 0xEC, 0x11 }
    local pi = 1
    while #bits < cap_bits do
        put(pads[pi], 8)
        pi = pi == 1 and 2 or 1
    end
    local bytes = {}
    for i = 1, #bits, 8 do
        local b = 0
        for j = 0, 7 do
            b = bor(lshift(b, 1), bits[i + j])
        end
        bytes[#bytes + 1] = b
    end
    return bytes
end

--- Block-split, RS-encode and interleave data + ECC into the final codeword stream.
---@param bytes integer[]
---@param v integer
---@return integer[]
local function build_codewords(bytes, v)
    local blocks = {}
    local idx = 1
    for _, g in ipairs(VER[v].groups) do
        for _ = 1, g[1] do
            local d = {}
            for _ = 1, g[2] do
                d[#d + 1] = bytes[idx]
                idx = idx + 1
            end
            blocks[#blocks + 1] = { data = d, ecc = rs_ecc(d, VER[v].ec) }
        end
    end
    local out = {}
    local maxd = 0
    for _, b in ipairs(blocks) do
        maxd = math.max(maxd, #b.data)
    end
    for i = 1, maxd do
        for _, b in ipairs(blocks) do
            if b.data[i] then
                out[#out + 1] = b.data[i]
            end
        end
    end
    for i = 1, VER[v].ec do
        for _, b in ipairs(blocks) do
            out[#out + 1] = b.ecc[i]
        end
    end
    return out
end

-- ── Matrix construction ────────────────────────────────────────────────────────────────
---@param size integer
---@return integer[][] matrix, boolean[][] reserved  -- both 0-indexed
local function new_matrix(size)
    local m, reserved = {}, {}
    for r = 0, size - 1 do
        m[r], reserved[r] = {}, {}
        for c = 0, size - 1 do
            m[r][c] = 0
            reserved[r][c] = false
        end
    end
    return m, reserved
end

local function place_finder(m, res, size, r0, c0)
    for r = -1, 7 do
        for c = -1, 7 do
            local r1, c1 = r0 + r, c0 + c
            if r1 >= 0 and r1 < size and c1 >= 0 and c1 < size then
                local dark = (r >= 0 and r <= 6 and (c == 0 or c == 6))
                    or (c >= 0 and c <= 6 and (r == 0 or r == 6))
                    or (r >= 2 and r <= 4 and c >= 2 and c <= 4)
                m[r1][c1] = dark and 1 or 0
                res[r1][c1] = true
            end
        end
    end
end

local function place_alignment(m, res, size, centres)
    for _, r in ipairs(centres) do
        for _, c in ipairs(centres) do
            local skip = (r == 6 and c == 6) or (r == 6 and c == size - 7) or (r == size - 7 and c == 6)
            if not skip then
                for dr = -2, 2 do
                    for dc = -2, 2 do
                        local dark = math.max(math.abs(dr), math.abs(dc)) ~= 1
                        m[r + dr][c + dc] = dark and 1 or 0
                        res[r + dr][c + dc] = true
                    end
                end
            end
        end
    end
end

local function place_timing(m, res, size)
    for i = 8, size - 9 do
        local v = (i % 2 == 0) and 1 or 0
        if not res[6][i] then
            m[6][i], res[6][i] = v, true
        end
        if not res[i][6] then
            m[i][6], res[i][6] = v, true
        end
    end
end

local function reserve_format(res, size)
    for i = 0, 8 do
        if i ~= 6 then
            res[8][i] = true
            res[i][8] = true
        end
    end
    for i = 0, 7 do
        res[8][size - 1 - i] = true
        res[size - 1 - i][8] = true
    end
    res[8][size - 8] = true
end

local function reserve_version(res, size)
    for i = 0, 5 do
        for j = 0, 2 do
            res[i][size - 11 + j] = true
            res[size - 11 + j][i] = true
        end
    end
end

--- Zig-zag data placement over the unreserved modules (right→left column pairs, skipping column 6).
local function place_data(m, res, size, stream)
    local bit_idx = 0
    local total_bits = #stream * 8
    local function next_bit()
        if bit_idx >= total_bits then
            return 0 -- remainder bits are 0
        end
        local byte = stream[math.floor(bit_idx / 8) + 1]
        local b = band(rshift(byte, 7 - (bit_idx % 8)), 1)
        bit_idx = bit_idx + 1
        return b
    end
    local col = size - 1
    local upward = true
    while col > 0 do
        if col == 6 then
            col = col - 1 -- skip the vertical timing column
        end
        for i = 0, size - 1 do
            local row = upward and (size - 1 - i) or i
            for c = col, col - 1, -1 do
                if not res[row][c] then
                    m[row][c] = next_bit()
                end
            end
        end
        upward = not upward
        col = col - 2
    end
end

-- ── Masking + penalty ────────────────────────────────────────────────────────────────
---@type table<integer, fun(r: integer, c: integer): boolean>
local MASK = {
    [0] = function(r, c)
        return (r + c) % 2 == 0
    end,
    [1] = function(r, _)
        return r % 2 == 0
    end,
    [2] = function(_, c)
        return c % 3 == 0
    end,
    [3] = function(r, c)
        return (r + c) % 3 == 0
    end,
    [4] = function(r, c)
        return (math.floor(r / 2) + math.floor(c / 3)) % 2 == 0
    end,
    [5] = function(r, c)
        return (r * c) % 2 + (r * c) % 3 == 0
    end,
    [6] = function(r, c)
        return ((r * c) % 2 + (r * c) % 3) % 2 == 0
    end,
    [7] = function(r, c)
        return ((r + c) % 2 + (r * c) % 3) % 2 == 0
    end,
}

local function apply_mask(m, res, size, mask)
    local out = {}
    for r = 0, size - 1 do
        out[r] = {}
        for c = 0, size - 1 do
            local v = m[r][c]
            if not res[r][c] and MASK[mask](r, c) then
                v = bxor(v, 1)
            end
            out[r][c] = v
        end
    end
    return out
end

--- The standard four-rule mask penalty (lower is better).
local function penalty(m, size)
    local score = 0
    -- Rule 1: same-colour runs ≥5 in each row / column.
    local function line_runs(get)
        local run, prev = 1, -1
        for k = 0, size - 1 do
            if get(k) == prev then
                run = run + 1
            else
                if run >= 5 then
                    score = score + 3 + (run - 5)
                end
                run, prev = 1, get(k)
            end
        end
        if run >= 5 then
            score = score + 3 + (run - 5)
        end
    end
    for r = 0, size - 1 do
        line_runs(function(c)
            return m[r][c]
        end)
    end
    for c = 0, size - 1 do
        line_runs(function(r)
            return m[r][c]
        end)
    end
    -- Rule 2: uniform 2×2 blocks.
    for r = 0, size - 2 do
        for c = 0, size - 2 do
            local v = m[r][c]
            if v == m[r][c + 1] and v == m[r + 1][c] and v == m[r + 1][c + 1] then
                score = score + 3
            end
        end
    end
    -- Rule 3: finder-like 1:1:3:1:1 patterns with four light modules on one side.
    local p1 = { 1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0 }
    local p2 = { 0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1 }
    local function match(get)
        for i = 0, size - 11 do
            local ok1, ok2 = true, true
            for k = 1, 11 do
                local v = get(i + k - 1)
                if v ~= p1[k] then
                    ok1 = false
                end
                if v ~= p2[k] then
                    ok2 = false
                end
            end
            if ok1 or ok2 then
                score = score + 40
            end
        end
    end
    for r = 0, size - 1 do
        match(function(c)
            return m[r][c]
        end)
    end
    for c = 0, size - 1 do
        match(function(r)
            return m[r][c]
        end)
    end
    -- Rule 4: dark-module balance.
    local dark = 0
    for r = 0, size - 1 do
        for c = 0, size - 1 do
            dark = dark + m[r][c]
        end
    end
    local pct = dark * 100 / (size * size)
    score = score + math.floor(math.abs(pct - 50) / 5) * 10
    return score
end

-- ── Format / version information ────────────────────────────────────────────────────────
---@param data5 integer
---@return integer
local function bch15(data5)
    local d = lshift(data5, 10)
    local g = 0x537
    for i = 4, 0, -1 do
        if band(rshift(d, i + 10), 1) == 1 then
            d = bxor(d, lshift(g, i))
        end
    end
    return bor(lshift(data5, 10), band(d, 0x3ff))
end

local function place_format(m, size, mask)
    local fmt = bxor(bch15(bor(lshift(0, 3), mask)), 0x5412) -- level M = 0b00
    local bits = {}
    for i = 14, 0, -1 do
        bits[#bits + 1] = band(rshift(fmt, i), 1)
    end
    local a = {
        { 8, 0 },
        { 8, 1 },
        { 8, 2 },
        { 8, 3 },
        { 8, 4 },
        { 8, 5 },
        { 8, 7 },
        { 8, 8 },
        { 7, 8 },
        { 5, 8 },
        { 4, 8 },
        { 3, 8 },
        { 2, 8 },
        { 1, 8 },
        { 0, 8 },
    }
    local b = {
        { size - 1, 8 },
        { size - 2, 8 },
        { size - 3, 8 },
        { size - 4, 8 },
        { size - 5, 8 },
        { size - 6, 8 },
        { size - 7, 8 },
        { 8, size - 8 },
        { 8, size - 7 },
        { 8, size - 6 },
        { 8, size - 5 },
        { 8, size - 4 },
        { 8, size - 3 },
        { 8, size - 2 },
        { 8, size - 1 },
    }
    for i = 1, 15 do
        m[a[i][1]][a[i][2]] = bits[i]
        m[b[i][1]][b[i][2]] = bits[i]
    end
    m[size - 8][8] = 1 -- dark module
end

local function place_version(m, size, v)
    local s = VERSION_INFO[v]
    if not s then
        return
    end
    local vbit = {}
    for i = 1, 18 do
        vbit[i] = tonumber(s:sub(19 - i, 19 - i)) -- vbit[1] = LSB
    end
    local k = 1
    for c = 0, 5 do
        for r = size - 11, size - 9 do
            m[r][c] = vbit[k]
            m[c][r] = vbit[k]
            k = k + 1
        end
    end
end

-- ── Public API ───────────────────────────────────────────────────────────────────────
---@class LvimPreviewQrMeta
---@field version integer
---@field size    integer  module count per side (no quiet zone)
---@field mask    integer  chosen mask pattern (0..7)

--- Encode `text` into a QR matrix. `force_mask` is for verification only; production omits it.
---@param text string
---@param force_mask integer?
---@return integer[][]? matrix  -- 0-indexed [row][col], 1 = dark; nil on error
---@return LvimPreviewQrMeta|string  -- meta on success, message on error
function M.encode(text, force_mask)
    local v = pick_version(#text)
    if not v then
        return nil, "text too long for a version-1..10 QR"
    end
    local size = 17 + 4 * v
    local stream = build_codewords(encode_data(text, v), v)

    local m, res = new_matrix(size)
    place_finder(m, res, size, 0, 0)
    place_finder(m, res, size, 0, size - 7)
    place_finder(m, res, size, size - 7, 0)
    place_alignment(m, res, size, ALIGN[v])
    place_timing(m, res, size)
    reserve_format(res, size)
    if v >= 7 then
        reserve_version(res, size)
    end
    place_data(m, res, size, stream)

    local best, best_mask, best_score = nil, 0, math.huge
    for mask = 0, 7 do
        if not force_mask or mask == force_mask then
            local cand = apply_mask(m, res, size, mask)
            place_format(cand, size, mask)
            if v >= 7 then
                place_version(cand, size, v)
            end
            local sc = penalty(cand, size)
            if sc < best_score then
                best, best_mask, best_score = cand, mask, sc
            end
        end
    end
    return best, { version = v, size = size, mask = best_mask }
end

-- Fixed black/white highlight groups (a QR needs true contrast, so these are NOT theme-derived).
-- '▀' fg = top module, bg = bottom module → four groups for the top/bottom dark/light combinations.
local HL = {
    dd = "LvimPreviewQrDark", -- top dark,  bottom dark
    dl = "LvimPreviewQrDarkLight", -- top dark,  bottom light
    ld = "LvimPreviewQrLightDark", -- top light, bottom dark
    ll = "LvimPreviewQrLight", -- top light, bottom light
}

--- (Re)define the four QR highlight groups. Idempotent; safe to call before every render.
function M.define_highlights()
    local black, white = "#000000", "#ffffff"
    vim.api.nvim_set_hl(0, HL.dd, { fg = black, bg = black })
    vim.api.nvim_set_hl(0, HL.dl, { fg = black, bg = white })
    vim.api.nvim_set_hl(0, HL.ld, { fg = white, bg = black })
    vim.api.nvim_set_hl(0, HL.ll, { fg = white, bg = white })
end

local UPPER_HALF = "▀" -- U+2580; 3 UTF-8 bytes
local UHB = #UPPER_HALF

--- Render a matrix to `lvim-ui.info` content: half-block lines + one highlight span per cell.
--- A `quiet`-module light border frames the code (required for scanning).
---@param matrix integer[][]
---@param size integer
---@param quiet integer?  quiet-zone width in modules (default 4)
---@return string[] lines, table[] highlights  -- highlights are { row, col_start, col_end, group }
function M.render(matrix, size, quiet)
    quiet = quiet or 4
    local dim = size + 2 * quiet
    -- val(r,c) over the padded grid: quiet zone (and out-of-range) is light (0).
    local function val(r, c)
        if r < 0 or c < 0 or r >= dim or c >= dim then
            return 0
        end
        local mr, mc = r - quiet, c - quiet
        if mr < 0 or mc < 0 or mr >= size or mc >= size then
            return 0
        end
        return matrix[mr][mc]
    end
    local lines, highlights = {}, {}
    local out_rows = math.ceil(dim / 2)
    for orow = 0, out_rows - 1 do
        local top_r = orow * 2
        local bot_r = top_r + 1
        local chars = {}
        for c = 0, dim - 1 do
            local top, bot = val(top_r, c), val(bot_r, c)
            local grp
            if top == 1 and bot == 1 then
                grp = HL.dd
            elseif top == 1 then
                grp = HL.dl
            elseif bot == 1 then
                grp = HL.ld
            else
                grp = HL.ll
            end
            chars[#chars + 1] = UPPER_HALF
            highlights[#highlights + 1] = { orow, c * UHB, (c + 1) * UHB, grp }
        end
        lines[#lines + 1] = table.concat(chars)
    end
    return lines, highlights
end

return M
