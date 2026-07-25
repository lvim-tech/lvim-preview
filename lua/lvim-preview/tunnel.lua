-- lvim-preview.tunnel: the optional auto-tunnel. When `config.tunnel.enabled`, `start` spawns a
-- process that forwards this loopback server to a PUBLIC address and PRINTS that address (the default
-- is `ssh -R … localhost.run` — zero-install, anonymous; cloudflared/ngrok work by swapping `cmd` +
-- `url_pattern`). The URL arrives asynchronously on the process's stdout/stderr, so this module
-- scrapes it out, publishes it as `state.tunnel_url` (which `reachable_url` prefers), and calls back
-- so the caller can raise the QR the moment the address is known. One process, killed on stop / exit.
--
-- Why a command + pattern and not a Lua function returning the URL: the address is not known until the
-- tunnel has connected (a network round trip), so a synchronous function would either block the editor
-- or return nil. Spawn-and-scrape is the honest shape for an asynchronously-assigned public address.
--
---@module "lvim-preview.tunnel"

local config = require("lvim-preview.config")
local state = require("lvim-preview.state")

local M = {}

--- Substitute `{port}` in each argv item.
---@param cmd string[]
---@param port integer
---@return string[]
local function build_argv(cmd, port)
    local argv = {}
    for _, a in ipairs(cmd or {}) do
        argv[#argv + 1] = (tostring(a):gsub("{port}", tostring(port)))
    end
    return argv
end

--- Start the tunnel for `port` if enabled and not already up, then call `on_url(url)` ONCE the public
--- URL is known (immediately if a tunnel is already up). No-op when `config.tunnel.enabled` is false.
---@param port integer
---@param on_url fun(url: string)
---@return nil
function M.ensure(port, on_url)
    local t = config.tunnel or {}
    if not t.enabled then
        return
    end
    if state.tunnel_url then -- already captured — reuse it
        on_url(state.tunnel_url)
        return
    end
    if state.tunnel_proc then -- spawned, URL still pending; the first ensure owns the callback
        return
    end

    local argv = build_argv(t.cmd or {}, port)
    if #argv == 0 then
        return
    end
    -- A configured `public_url` (a named / custom-domain tunnel that always answers on the SAME
    -- address, printing nothing to discover) is the URL as-is — the process still runs, just for the
    -- connection. Only a dynamic-address provider (localhost.run's random subdomain) is scraped.
    local static = config.public_url
    static = type(static) == "string" and static ~= "" and static or nil
    local pattern = t.url_pattern or "https://%S+"
    -- Chunks are not line-aligned, so accumulate and scan the running buffer; fire the callback once.
    local acc, fired = "", false
    local function scan(data)
        if static or fired or not data or data == "" then
            return
        end
        acc = acc .. data
        local url = acc:match(pattern)
        if url then
            fired = true
            state.tunnel_url = url
            vim.schedule(function()
                on_url(url)
            end)
        end
    end

    local ok, proc = pcall(vim.system, argv, {
        text = true,
        stdout = function(_, data)
            scan(data)
        end,
        stderr = function(_, data)
            scan(data)
        end,
    }, function()
        -- The tunnel process exited (dropped / killed): forget the URL so a later start re-establishes.
        vim.schedule(function()
            state.tunnel_proc = nil
            state.tunnel_url = nil
        end)
    end)
    if not ok then
        vim.schedule(function()
            vim.notify("lvim-preview: could not start the tunnel: " .. tostring(proc), vim.log.levels.ERROR)
        end)
        return
    end
    state.tunnel_proc = proc

    -- Static address: it is reachable as soon as the process is up — announce it now (reachable_url
    -- reads config.public_url when state.tunnel_url is unset), no output to wait for.
    if static then
        vim.schedule(function()
            on_url(static)
        end)
    end

    -- Never leave an orphan tunnel behind when Neovim quits.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        once = true,
        callback = function()
            M.stop()
        end,
    })
end

--- Terminate the tunnel process (if any) and clear its URL.
---@return nil
function M.stop()
    if state.tunnel_proc then
        pcall(function()
            state.tunnel_proc:kill(15) -- SIGTERM
        end)
        state.tunnel_proc = nil
    end
    state.tunnel_url = nil
end

return M
