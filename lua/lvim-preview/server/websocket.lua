-- lvim-preview.server.websocket: the RFC 6455 layer — the opening handshake and the frame
-- codec. Only what a browser live-preview needs:
--   * handshake  — validate `Sec-WebSocket-Key`, reply 101 with base64(SHA1(key .. GUID)).
--   * encode     — server→client TEXT frames, UNMASKED (a server MUST NOT mask; RFC 5.1),
--                  with the 7 / 7+16 / 7+64 payload-length forms and a pong/close helper.
--   * decode     — client→server frames are ALWAYS masked (RFC 5.1); we unmask on read. The
--                  browser only ever sends control frames (ping/pong/close) at us — the page is
--                  a passive viewer — so a data frame is parsed but its payload is ignored (the
--                  safety rule: the browser never drives the editor). A frame can straddle TCP
--                  reads, so decode is a STREAM parser: it consumes whole frames out of a
--                  growing buffer and hands the remainder back for the next chunk.
--
-- bit ops run on LuaJIT `bit` (Neovim). Payload lengths above 2^31 are irrelevant here (we push
-- small JSON), so the 64-bit length branch reads the low 32 bits only.
--
---@module "lvim-preview.server.websocket"

local bit = require("bit")
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local rshift = bit.rshift
local sha1 = require("lvim-preview.server.sha1")

local M = {}

-- The RFC 6455 magic GUID appended to the client key before hashing.
local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

---@class WsFrame
---@field opcode integer  4-bit opcode (0x1 text, 0x2 binary, 0x8 close, 0x9 ping, 0xA pong)
---@field fin    boolean  final-fragment bit
---@field payload string  unmasked payload bytes

--- Build the 101 Switching Protocols response for a parsed request, or nil when the request
--- is not a valid WebSocket upgrade (missing key).
---@param request string  the full HTTP request head
---@return string? response
function M.handshake_response(request)
    local key = request:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Kk]ey:%s*([^\r\n]+)")
    if not key then
        return nil
    end
    local accept = vim.base64.encode(sha1.digest(vim.trim(key) .. WS_GUID))
    return "HTTP/1.1 101 Switching Protocols\r\n"
        .. "Upgrade: websocket\r\n"
        .. "Connection: Upgrade\r\n"
        .. "Sec-WebSocket-Accept: "
        .. accept
        .. "\r\n\r\n"
end

--- Encode one unmasked frame with the given opcode and payload.
---@param opcode integer
---@param payload string
---@return string frame
local function encode(opcode, payload)
    local len = #payload
    local b1 = string.char(bor(0x80, opcode)) -- FIN + opcode
    local header
    if len <= 125 then
        header = b1 .. string.char(len)
    elseif len <= 0xFFFF then
        header = b1 .. string.char(126) .. string.char(rshift(len, 8), band(len, 0xFF))
    else
        -- 64-bit length; high word is zero for our payload sizes.
        header = b1
            .. string.char(127)
            .. string.char(
                0,
                0,
                0,
                0,
                band(rshift(len, 24), 0xFF),
                band(rshift(len, 16), 0xFF),
                band(rshift(len, 8), 0xFF),
                band(len, 0xFF)
            )
    end
    return header .. payload
end

--- Encode a server→client TEXT frame.
---@param text string
---@return string frame
function M.text_frame(text)
    return encode(0x1, text)
end

--- Encode a PONG frame echoing a ping's payload.
---@param payload string
---@return string frame
function M.pong_frame(payload)
    return encode(0xA, payload)
end

--- Encode a CLOSE frame (empty payload = 1000-ish no-status close).
---@return string frame
function M.close_frame()
    return encode(0x8, "")
end

--- Encode a JSON message as a TEXT frame.
---@param message table
---@return string frame
function M.json_frame(message)
    return M.text_frame(vim.json.encode(message))
end

--- Pull as many complete frames as `buffer` holds. Returns the decoded frames (in order) and
--- the unconsumed remainder (an incomplete frame's leading bytes) to carry into the next read.
--- Malformed/oversized headers are treated as "need more bytes" — the caller keeps buffering.
---@param buffer string
---@return WsFrame[] frames, string rest
function M.decode(buffer)
    local frames = {}
    local pos = 1
    local n = #buffer
    while true do
        if n - pos + 1 < 2 then
            break
        end
        local b1 = buffer:byte(pos)
        local b2 = buffer:byte(pos + 1)
        local fin = band(b1, 0x80) ~= 0
        local opcode = band(b1, 0x0F)
        local masked = band(b2, 0x80) ~= 0
        local len = band(b2, 0x7F)
        local off = pos + 2
        if len == 126 then
            if n - off + 1 < 2 then
                break
            end
            len = buffer:byte(off) * 0x100 + buffer:byte(off + 1)
            off = off + 2
        elseif len == 127 then
            if n - off + 1 < 8 then
                break
            end
            -- low 32 bits only (our frames are small); high 4 bytes ignored.
            len = buffer:byte(off + 4) * 0x1000000
                + buffer:byte(off + 5) * 0x10000
                + buffer:byte(off + 6) * 0x100
                + buffer:byte(off + 7)
            off = off + 8
        end
        local mask
        if masked then
            if n - off + 1 < 4 then
                break
            end
            mask = { buffer:byte(off, off + 3) }
            off = off + 4
        end
        if n - off + 1 < len then
            break -- payload not fully arrived yet
        end
        local payload = buffer:sub(off, off + len - 1)
        if masked then
            -- Unmask: payload[i] XOR mask[(i-1) mod 4].
            local out = {}
            for i = 1, len do
                out[i] = string.char(bxor(payload:byte(i), mask[(i - 1) % 4 + 1]))
            end
            payload = table.concat(out)
        end
        frames[#frames + 1] = { opcode = opcode, fin = fin, payload = payload }
        pos = off + len
    end
    return frames, buffer:sub(pos)
end

-- Re-exported for the http layer's upgrade detection.
M.WS_GUID = WS_GUID

return M
