-- lvim-preview.server.sha1: a small pure-Lua SHA-1 (FIPS 180-1), used for ONE thing only —
-- the RFC 6455 WebSocket opening handshake, whose `Sec-WebSocket-Accept` is
-- base64(SHA1(key .. GUID)). Neovim's `vim.hash`/`vim.base64` cover base64 but only ship
-- sha256, never sha1, so the digest has to be computed here. The arithmetic runs on LuaJIT's
-- `bit` module (always present in Neovim's LuaJIT) — 32-bit two's-complement ops, so every
-- add is masked back to 32 bits before it can overflow a Lua number.
--
-- Not a general hashing utility: it is deliberately confined to the handshake and returns the
-- raw 20-byte digest (the caller base64-encodes it), never a hex string.
--
---@module "lvim-preview.server.sha1"

local bit = require("bit")
local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local rol, tobit = bit.rol, bit.tobit

local M = {}

-- 32-bit unsigned add: LuaJIT `bit` ops yield signed 32-bit; SHA-1 defines addition modulo
-- 2^32, so the running values are kept as bit-exact 32-bit words via `tobit` and read back
-- unsigned only at the very end.
---@param a integer
---@param b integer
---@return integer
local function add32(a, b)
    return tobit(a + b)
end

-- Pack a 32-bit word big-endian into 4 bytes.
---@param n integer
---@return string
local function word_to_bytes(n)
    return string.char(
        band(bit.rshift(n, 24), 0xFF),
        band(bit.rshift(n, 16), 0xFF),
        band(bit.rshift(n, 8), 0xFF),
        band(n, 0xFF)
    )
end

--- SHA-1 digest of `message`, returned as the raw 20-byte binary string.
---@param message string
---@return string  20 raw bytes
function M.digest(message)
    local len = #message
    -- Pad: 0x80, then zeros, then the 64-bit big-endian bit length, to a multiple of 64 bytes.
    -- The message length is well under 2^32 bits here (a handshake key), so the high 32 bits of
    -- the length field are always zero.
    local bitlen = len * 8
    local padded = message .. "\128"
    local zero = (56 - (len + 1) % 64) % 64
    padded = padded .. string.rep("\0", zero) .. string.rep("\0", 4) .. word_to_bytes(tobit(bitlen))

    local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
    h0, h1, h2, h3, h4 = tobit(h0), tobit(h1), tobit(h2), tobit(h3), tobit(h4)

    local w = {}
    for chunk = 1, #padded, 64 do
        for i = 0, 15 do
            local p = chunk + i * 4
            local b1, b2, b3, b4 = padded:byte(p, p + 3)
            w[i] = tobit(b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4)
        end
        for i = 16, 79 do
            w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
        end

        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then
                f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
            elseif i < 40 then
                f, k = bxor(b, c, d), 0x6ED9EBA1
            elseif i < 60 then
                f, k = bor(bor(band(b, c), band(b, d)), band(c, d)), 0x8F1BBCDC
            else
                f, k = bxor(b, c, d), 0xCA62C1D6
            end
            local temp = add32(add32(add32(add32(rol(a, 5), f), e), tobit(k)), w[i])
            e, d, c, b, a = d, c, rol(b, 30), a, temp
        end

        h0, h1, h2, h3, h4 = add32(h0, a), add32(h1, b), add32(h2, c), add32(h3, d), add32(h4, e)
    end

    return word_to_bytes(h0) .. word_to_bytes(h1) .. word_to_bytes(h2) .. word_to_bytes(h3) .. word_to_bytes(h4)
end

return M
