-- lvim-preview.browser: resolve the browser opener and launch it on the preview URL. Default
-- (config.browser = nil) delegates to Neovim's own platform opener (vim.ui.open → xdg-open /
-- open / start). An override is either a command string (split on whitespace) or an argv list
-- ({ "firefox", "--new-window" }) — always spawned via vim.system as a LIST, never a shell
-- string, so a URL or a path with odd characters can't be reinterpreted by a shell.
--
---@module "lvim-preview.browser"

local M = {}

--- Open `url` in the configured browser (or the system default).
---@param url string
---@param browser string|string[]|nil
---@return nil
function M.open(url, browser)
    if browser == nil or browser == "" then
        -- Native platform opener (handles Linux/macOS/Windows selection itself).
        -- Through the shared opener: `vim.ui.open` signals a missing handler by RETURNING `nil, err`
        -- rather than raising, so neither a bare `pcall` status nor its second value is the answer.
        local opened, why = require("lvim-utils.utils").open_url(url)
        if not opened then
            vim.notify("lvim-preview: could not open the browser: " .. (why or "?"), vim.log.levels.WARN)
        end
        return
    end

    ---@type string[]
    local argv
    if type(browser) == "table" then
        argv = vim.list_slice(browser, 1, #browser)
    else
        argv = vim.split(browser, "%s+", { trimempty = true })
    end
    argv[#argv + 1] = url

    local ok, err = pcall(vim.system, argv, { detach = true })
    if not ok then
        vim.notify(("lvim-preview: could not launch %s: %s"):format(argv[1] or "?", tostring(err)), vim.log.levels.WARN)
    end
end

return M
