-- lvim-preview.health: :checkhealth lvim-preview. Reports the things that make a live preview
-- fail in ways the browser alone cannot explain: a Neovim too old for the uv/base64/system APIs
-- the server leans on, a missing LuaJIT `bit` (the WS handshake needs sha1), the optional
-- ecosystem integrations (lvim-ui picker, lvim-hud chip, lvim-icons, lvim-utils palette theme),
-- a browser opener that is not resolvable, a config that is internally inconsistent, the
-- SECURITY posture of a non-loopback bind (LAN-exposed, no auth), and — the offline guarantee —
-- the integrity/presence of every vendored render asset. Read-only: it never mutates state.
--
---@module "lvim-preview.health"

local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local util = require("lvim-preview.util")

local M = {}

-- The plugin's static/ dir (resolved from this file's path — no runtime dependency).
local STATIC_DIR = (function()
    local this = debug.getinfo(1, "S").source:sub(2)
    return (vim.fs.normalize(this):gsub("/lua/lvim%-preview/health%.lua$", "/static"))
end)()

-- Every vendored asset the served page can load — the offline guarantee depends on all of them
-- being present. Grouped by feature so a partial vendor tree points at the exact gap.
local VENDOR = {
    { "vendor/markdown-it/markdown-it.min.js", "markdown renderer" },
    { "vendor/markdown-it/markdown-it-emoji.min.js", "emoji" },
    { "vendor/markdown-it/LICENSE", "markdown-it license" },
    { "vendor/katex/katex.min.js", "KaTeX" },
    { "vendor/katex/katex.min.css", "KaTeX css" },
    { "vendor/katex/contrib/auto-render.min.js", "KaTeX auto-render" },
    { "vendor/katex/fonts/KaTeX_Main-Regular.woff2", "KaTeX fonts" },
    { "vendor/katex/LICENSE", "KaTeX license" },
    { "vendor/mermaid/mermaid.min.js", "Mermaid" },
    { "vendor/mermaid/LICENSE", "Mermaid license" },
    { "vendor/highlight/highlight.min.js", "highlight.js" },
    { "vendor/highlight/github.min.css", "highlight.js light theme" },
    { "vendor/highlight/github-dark.min.css", "highlight.js dark theme" },
    { "vendor/highlight/LICENSE", "highlight.js license" },
    { "vendor/github-markdown-css/github-markdown.css", "github-markdown css" },
    { "vendor/github-markdown-css/LICENSE", "github-markdown-css license" },
    { "vendor/asciidoctor/asciidoctor.min.js", "AsciiDoc renderer" },
    { "vendor/asciidoctor/asciidoctor.min.css", "AsciiDoc css" },
    { "vendor/asciidoctor/LICENSE", "AsciiDoc license" },
    { "client.js", "browser client" },
    { "style.css", "base stylesheet" },
    { "vendor/README", "vendor manifest" },
}

--- Whether a path is a readable, non-empty file.
---@param path string
---@return boolean ok, integer size
local function present(path)
    local st = vim.uv.fs_stat(path)
    if not st or st.type ~= "file" then
        return false, 0
    end
    return st.size > 0, st.size
end

--- Neovim version + LuaJIT bit (the two hard runtime requirements).
---@param h table
local function check_runtime(h)
    -- vim.fs.root (0.10), vim.base64 (0.10), vim.system (0.10) — all needed.
    if vim.fn.has("nvim-0.10") == 1 then
        h.ok("Neovim >= 0.10 (vim.uv, vim.base64, vim.system, vim.fs.root)")
    else
        h.error("Neovim >= 0.10 is required (vim.uv / vim.base64 / vim.system / vim.fs.root)")
    end
    local ok_bit = pcall(require, "bit")
    if ok_bit then
        h.ok("LuaJIT `bit` present (WebSocket handshake SHA-1)")
    else
        h.error("LuaJIT `bit` missing — the WebSocket handshake SHA-1 cannot run")
    end
end

--- Optional ecosystem integrations.
---@param h table
local function check_integrations(h)
    local ok_colors, colors = pcall(require, "lvim-utils.colors")
    if ok_colors and type(colors.blend) == "function" then
        h.ok('lvim-utils palette found (theme = "lvim" tracks the editor)')
    else
        h.warn('lvim-utils not found — theme = "lvim" falls back to a fixed dark palette')
    end
    for _, mod in ipairs({
        { "lvim-ui", ":LvimPreview pick chooser" },
        { "lvim-hud.overlay", "serving chip" },
        { "lvim-icons", "per-file icons in the chooser" },
    }) do
        if pcall(require, mod[1]) then
            h.ok(("%s found (%s)"):format(mod[1], mod[2]))
        else
            h.info(("%s not found — %s degrades gracefully"):format(mod[1], mod[2]))
        end
    end
end

--- Browser opener resolvability.
---@param h table
local function check_browser(h)
    if config.browser and config.browser ~= "" then
        local cmd = type(config.browser) == "table" and config.browser[1]
            or vim.split(config.browser, "%s+", { trimempty = true })[1]
        if cmd and vim.fn.executable(cmd) == 1 then
            h.ok(("browser opener: %s"):format(cmd))
        else
            h.warn(("configured browser `%s` is not executable on PATH"):format(tostring(cmd)))
        end
        return
    end
    -- System opener (vim.ui.open → xdg-open / open / start / wslview).
    local openers = { "xdg-open", "open", "start", "wslview" }
    for _, o in ipairs(openers) do
        if vim.fn.executable(o) == 1 then
            h.ok(("system browser opener available: %s"):format(o))
            return
        end
    end
    h.warn("no system opener (xdg-open/open/start/wslview) found — set config.browser or open the URL manually")
end

--- Config validity + the security posture of the bind address.
---@param h table
local function check_config(h)
    local problems = 0
    if type(config.port) ~= "number" or config.port < 1 or config.port > 65535 then
        h.error(("port must be 1..65535 (got %s)"):format(vim.inspect(config.port)))
        problems = problems + 1
    end
    local themes = { lvim = true, light = true, dark = true, auto = true }
    if not themes[config.theme] then
        h.error(('theme must be "lvim"|"light"|"dark"|"auto" (got %s)'):format(vim.inspect(config.theme)))
        problems = problems + 1
    end
    if type(config.debounce) ~= "number" or config.debounce < 0 then
        h.error(("debounce must be a number >= 0 (got %s)"):format(vim.inspect(config.debounce)))
        problems = problems + 1
    end
    if problems == 0 then
        h.ok(
            ("config valid (port=%d, theme=%s, root=%s, debounce=%dms)"):format(
                config.port,
                config.theme,
                tostring(config.root),
                config.debounce
            )
        )
    end

    -- SECURITY: a non-loopback bind exposes the preview AND every file under the root to the LAN
    -- with NO authentication. This is opt-in by config only; surface it loudly.
    if util.is_loopback(config.address) then
        h.ok(("bind address %s is loopback-only"):format(config.address))
    else
        h.warn(
            ("bind address %s is NON-loopback — the preview and every file under the root are reachable by any host on the network, with NO authentication"):format(
                config.address
            )
        )
    end
    if config.serve_hidden then
        h.warn("serve_hidden is ON — dotfiles under the root (.env, .git/…) are servable")
    end
end

--- Vendored-asset integrity — the offline / no-CDN guarantee.
---@param h table
local function check_vendor(h)
    local missing = {}
    local total = 0
    for _, entry in ipairs(VENDOR) do
        total = total + 1
        local ok = present(STATIC_DIR .. "/" .. entry[1])
        if not ok then
            missing[#missing + 1] = entry[1] .. " (" .. entry[2] .. ")"
        end
    end
    if #missing == 0 then
        h.ok(("all %d vendored render assets present (offline-safe, no CDN)"):format(total))
    else
        h.error(
            ("%d/%d vendored assets missing — re-vendor per static/vendor/README:\n  - %s"):format(
                #missing,
                total,
                table.concat(missing, "\n  - ")
            )
        )
    end
end

--- Live server status.
---@param h table
local function check_server(h)
    if state.running then
        local scope = util.is_loopback(state.host) and "loopback" or "LAN-EXPOSED"
        h.info(
            ("server running on http://%s:%d (%s), %d client(s), previewing: %s"):format(
                state.host,
                state.port,
                scope,
                #state.clients,
                state.file or "-"
            )
        )
    else
        h.info("server not running (start with :LvimPreview start)")
    end
end

--- Run the health report.
---@return nil
function M.check()
    local h = vim.health
    h.start("lvim-preview")
    check_runtime(h)
    check_integrations(h)
    check_browser(h)
    check_config(h)
    check_vendor(h)
    check_server(h)
end

return M
