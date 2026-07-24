-- lvim-preview.server: the libuv TCP lifecycle and the per-client read loop that multiplexes
-- HTTP and WebSocket on the same socket. One listener per Neovim instance.
--
-- Threading: bind/listen are driven from the main thread (start/stop), but every listen/read
-- callback runs in a libuv "fast" context — so anything touching editor state (a connect
-- notification) is `vim.schedule`-wrapped, while the request/serve/frame work stays in pure
-- string + uv land (see server.http / server.websocket).
--
-- A connection starts as HTTP: bytes accumulate until the `\r\n\r\n` head is complete, then it
-- either UPGRADES to WebSocket (kept open, registered for broadcasts, subsequent bytes parsed
-- as frames) or is served one GET response and closed. Server→client pushes (reload / update /
-- scroll / theme) are broadcast to every upgraded client, so several browser tabs stay in sync.
--
---@module "lvim-preview.server"

local uv = vim.uv
local http = require("lvim-preview.server.http")
local websocket = require("lvim-preview.server.websocket")
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")

local M = {}

---@class LvimPreviewClientCtx
---@field tcp uv.uv_tcp_t   the accepted socket
---@field upgraded boolean  true once the WebSocket handshake completed
---@field buf string        pending bytes (HTTP head before upgrade, then WS frame remainder)

--- Schedule-safe notify (never call vim.notify directly from a fast callback).
---@param msg string
---@param level integer?
local function notify(msg, level)
    if not config.notify then
        return
    end
    vim.schedule(function()
        vim.notify("lvim-preview: " .. msg, level or vim.log.levels.INFO)
    end)
end

--- Remove a client from the broadcast registry and close its socket (idempotent).
---@param ctx LvimPreviewClientCtx
local function drop_client(ctx)
    for i, c in ipairs(state.clients) do
        if c == ctx then
            table.remove(state.clients, i)
            break
        end
    end
    pcall(function()
        if ctx.tcp and not ctx.tcp:is_closing() then
            ctx.tcp:close()
        end
    end)
end

--- Handle bytes on an already-upgraded WebSocket client: decode whole frames out of the
--- rolling buffer and act on control frames. Data frames are parsed but ignored — the browser
--- is a passive viewer and must never drive the editor (safety rule).
---@param ctx LvimPreviewClientCtx
---@param chunk string
local function on_ws_bytes(ctx, chunk)
    ctx.buf = ctx.buf .. chunk
    local frames, rest = websocket.decode(ctx.buf)
    ctx.buf = rest
    for _, f in ipairs(frames) do
        if f.opcode == 0x8 then -- close
            pcall(function()
                ctx.tcp:write(websocket.close_frame())
            end)
            return drop_client(ctx)
        elseif f.opcode == 0x9 then -- ping → pong
            pcall(function()
                ctx.tcp:write(websocket.pong_frame(f.payload))
            end)
        end
        -- 0xA pong and 0x1/0x2 data frames: ignored.
    end
end

--- Handle bytes on a not-yet-upgraded connection: accumulate the HTTP head, then upgrade or
--- serve one response.
---@param ctx LvimPreviewClientCtx
---@param chunk string
local function on_http_bytes(ctx, chunk)
    ctx.buf = ctx.buf .. chunk
    -- Wait for the end of the header block. GET has no body, so this is the whole request.
    if not ctx.buf:find("\r\n\r\n", 1, true) then
        return
    end
    local request = ctx.buf
    if http.is_upgrade(request) then
        local response = websocket.handshake_response(request)
        if not response then
            return drop_client(ctx)
        end
        ctx.tcp:write(response)
        ctx.upgraded = true
        ctx.buf = ""
        state.clients[#state.clients + 1] = ctx
        notify(("browser connected (%d client%s)"):format(#state.clients, #state.clients == 1 and "" or "s"))
    else
        -- One-shot GET: serve and close. This ctx was never registered for broadcasts.
        http.serve(ctx.tcp, request)
    end
end

--- Accept and wire up one incoming connection.
---@param server uv.uv_tcp_t
local function on_connection(server)
    local client = uv.new_tcp()
    if not client then
        return
    end
    local ok = pcall(function()
        server:accept(client)
    end)
    if not ok then
        pcall(function()
            client:close()
        end)
        return
    end
    ---@type LvimPreviewClientCtx
    local ctx = { tcp = client, upgraded = false, buf = "" }
    client:read_start(function(err, chunk)
        if err or not chunk then
            return drop_client(ctx)
        end
        if ctx.upgraded then
            on_ws_bytes(ctx, chunk)
        else
            on_http_bytes(ctx, chunk)
        end
    end)
end

--- Try to bind `host:port`; on EADDRINUSE with auto_port, scan upward up to `limit` ports.
--- Returns the bound listener and the chosen port, or nil + an error string.
---@param host string
---@param port integer
---@param limit integer  max ports to try
---@return uv.uv_tcp_t? listener, integer|string  port_or_error
local function bind_scan(host, port, limit)
    for p = port, port + limit - 1 do
        local server = uv.new_tcp()
        if not server then
            return nil, "could not create a TCP handle"
        end
        local ok, err = pcall(function()
            server:bind(host, p)
        end)
        if ok then
            return server, p
        end
        pcall(function()
            server:close()
        end)
        local es = tostring(err)
        local busy = es:match("EADDRINUSE") or es:match("address already in use")
        if not busy or not config.auto_port then
            return nil, es
        end
    end
    return nil, ("no free port in %d..%d"):format(port, port + limit - 1)
end

--- Whether the server is currently listening.
---@return boolean
function M.is_running()
    return state.running
end

--- Number of connected (upgraded) browser clients.
---@return integer
function M.client_count()
    return #state.clients
end

--- Start the server bound to `host:port` (auto_port may pick a nearby port). Idempotent guard:
--- refuses to start a second listener. Sets state.host / state.port / state.running.
---@param host string
---@param port integer
---@return boolean ok, string? err
function M.start(host, port)
    if state.running then
        return true
    end
    local limit = config.auto_port and 50 or 1
    local server, chosen = bind_scan(host, port, limit)
    if not server then
        return false, tostring(chosen)
    end
    ---@cast chosen integer
    local ok, err = pcall(function()
        server:listen(128, function(lerr)
            if lerr then
                notify("listen error: " .. tostring(lerr), vim.log.levels.ERROR)
                return
            end
            on_connection(server)
        end)
    end)
    if not ok then
        pcall(function()
            server:close()
        end)
        return false, tostring(err)
    end
    state.listener = server
    state.host = host
    state.port = chosen
    state.running = true
    return true
end

--- Broadcast a JSON message to every connected client. A write failure drops that client.
---@param message table
function M.broadcast(message)
    if #state.clients == 0 then
        return
    end
    local frame = websocket.json_frame(message)
    -- iterate a copy: drop_client mutates state.clients
    local snapshot = vim.list_slice(state.clients, 1, #state.clients)
    for _, ctx in ipairs(snapshot) do
        local ok = pcall(function()
            ctx.tcp:write(frame)
        end)
        if not ok then
            drop_client(ctx)
        end
    end
end

--- Stop the server: close every client socket, then the listener (no orphaned port). Clears
--- the session state's connection fields but leaves the previewed-file bookkeeping to init.
function M.stop()
    for _, ctx in ipairs(vim.list_slice(state.clients, 1, #state.clients)) do
        drop_client(ctx)
    end
    state.clients = {}
    if state.listener and not state.listener:is_closing() then
        pcall(function()
            state.listener:close()
        end)
    end
    state.listener = nil
    state.running = false
end

return M
