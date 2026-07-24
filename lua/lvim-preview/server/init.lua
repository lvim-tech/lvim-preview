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
-- The reverse path is deliberately narrow and is described where it is enforced, on `on_ws_bytes`.
--
---@module "lvim-preview.server"

local uv = vim.uv
local http = require("lvim-preview.server.http")
local websocket = require("lvim-preview.server.websocket")
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")

local M = {}

-- Largest HTTP request head buffered before the terminating blank line. A browser GET head is
-- a couple of KB at most (cookies included); past this the peer is not speaking HTTP at us.
local MAX_HEAD = 32 * 1024

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
--- rolling buffer and act on control frames.
---
--- DATA frames are discarded by default — the browser is a passive viewer and must never drive
--- the editor (safety rule). There are exactly TWO relaxations, each with its OWN config flag and
--- its own narrow acceptance test, and neither can widen the other:
---   * `config.artifact.allow_client_messages` — inverse search for build ARTIFACTS. The artifact
---     module then drops anything that does not address a registered artifact whose producer
---     supplied an `on_message` handler.
---   * `config.sync_scroll_back.enabled` — browser→editor sync SCROLL for a previewed DOCUMENT.
---     The scroll module accepts one single message shape (`type = "scroll_source"` with a `path`
---     and a `line`) addressed to a currently previewed markdown/org document, and discards
---     everything else.
--- A frame is offered to each enabled gate and the gates never see each other's messages: an
--- artifact page's message finds no document, a document's message finds no artifact, and an
--- unknown message from either kind of connection is discarded exactly as it was before either
--- relaxation existed. With both flags off — the default — every data frame is still dropped here.
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
        elseif f.opcode == 0x1 then
            -- Inline requires: both modules require this one for broadcast, so hoisting either
            -- would be a load-time cycle.
            if config.artifact.allow_client_messages then
                require("lvim-preview.artifact").dispatch_client_message(f.payload)
            end
            if config.sync_scroll_back.enabled then
                require("lvim-preview.scroll").dispatch_client_message(f.payload)
            end
        end
        -- 0xA pong and 0x2 binary frames: ignored.
    end
end

--- Stop reading from a connection whose HTTP life is over. The response path writes then closes
--- the handle itself; leaving `read_start` armed would let any further bytes re-enter the parser
--- with the finished head still buffered and drive a second serve against a closing socket.
---@param ctx LvimPreviewClientCtx
local function finish_http(ctx)
    ctx.buf = ""
    pcall(function()
        ctx.tcp:read_stop()
    end)
end

--- Handle bytes on a not-yet-upgraded connection: accumulate the HTTP head, then upgrade or
--- serve one response.
---@param ctx LvimPreviewClientCtx
---@param chunk string
local function on_http_bytes(ctx, chunk)
    ctx.buf = ctx.buf .. chunk
    -- Wait for the end of the header block. GET has no body, so this is the whole request.
    if not ctx.buf:find("\r\n\r\n", 1, true) then
        -- A client that streams bytes and never sends the blank line must not grow this buffer
        -- without bound. A real browser request head is far under the cap; the loopback default
        -- makes the sender local, but a LAN bind (an explicit act) makes it remote.
        if #ctx.buf > MAX_HEAD then
            local tcp = ctx.tcp
            finish_http(ctx)
            http.refuse(tcp, "431 Request Header Fields Too Large")
        end
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
        -- One-shot GET: every response carries `Connection: close`, so this connection is
        -- finished the moment it is handed to the serve path. This ctx was never registered
        -- for broadcasts.
        local tcp = ctx.tcp
        finish_http(ctx)
        http.serve(tcp, request)
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

--- Is another lvim-preview server ALREADY listening on host:port (a second Neovim)? A short,
--- synchronous libuv probe: connect, send a bare GET, look for our `Server: lvim-preview` header.
--- Times out fast — a busy port that is NOT us (some other program) simply answers "no".
---@param host string
---@param port integer
---@return boolean
local function ours_on(host, port)
    local done, result = false, false
    local c = uv.new_tcp()
    local timer = uv.new_timer()
    local function finish(v)
        if done then
            return
        end
        done = true
        result = v
        pcall(function()
            timer:stop()
            timer:close()
        end)
        pcall(function()
            if c and not c:is_closing() then
                c:close()
            end
        end)
    end
    timer:start(400, 0, function()
        finish(false)
    end)
    c:connect(host, port, function(err)
        if err then
            return finish(false)
        end
        c:write("GET /@lvim-preview/ HTTP/1.0\r\nHost: probe\r\n\r\n")
        c:read_start(function(rerr, chunk)
            if rerr or not chunk then
                return finish(false)
            end
            finish(chunk:lower():find("server: lvim-preview", 1, true) ~= nil)
        end)
    end)
    vim.wait(500, function()
        return done
    end)
    return result
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
        -- A port taken by ANOTHER lvim-preview (a second Neovim) is the trap that reads as "nothing
        -- updates": edits go to this instance's server on a bumped port while the browser watches
        -- the other one. Auto_port would hide it, so say it out loud, ONCE, on the preferred port.
        if busy and p == port and ours_on(host, p) then
            -- A real collision with another Neovim. Record it so preview_file does NOT auto-open a
            -- browser tab: a fresh tab on the bumped port is exactly the misleading thing — it looks
            -- like the preview opened, but it is a second server the user never meant to start.
            state.collided_port = p
            notify(
                ("port %d is already serving lvim-preview from another Neovim instance — not opening a "):format(p)
                    .. "browser. Close the other Neovim, or open this buffer's own URL by hand (see below).",
                vim.log.levels.WARN
            )
        end
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
    state.collided_port = nil
    -- CHECK FOR ANOTHER lvim-preview FIRST, before binding. libuv sets SO_REUSEADDR, so on loopback a
    -- second bind to the SAME port can SUCCEED — two servers listening, the browser talking to one
    -- while this instance edits the buffer behind the other. There is then no EADDRINUSE to react to,
    -- so the only reliable signal is to probe the port up front. A collision skips the preferred port
    -- and scans from the next one, and records itself so preview_file does not auto-open a stray tab.
    local start_port = port
    if ours_on(host, port) then
        state.collided_port = port
        notify(
            ("port %d is already serving lvim-preview from ANOTHER Neovim instance. A browser tab on %d "):format(
                port,
                port
            )
                .. "is controlled by that other Neovim, not this buffer — not opening one. Close the other "
                .. "Neovim, or open this buffer's own URL by hand (shown below).",
            vim.log.levels.WARN
        )
        start_port = port + 1
    end
    local limit = config.auto_port and 50 or 1
    local server, chosen = bind_scan(host, start_port, limit)
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
