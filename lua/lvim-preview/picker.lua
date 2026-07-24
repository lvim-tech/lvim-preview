-- lvim-preview.picker: the `:LvimPreview pick` chooser — a centred, themed lvim-ui select over
-- every previewable file under the servable root. Rows carry a per-file lvim-icons glyph and a
-- root-relative label; the currently previewed file is focused on open (current_item). Picking
-- one previews it (re-rooting if root = "file"). Never vim.ui.select — always the canonical
-- lvim-ui primitive.
--
---@module "lvim-preview.picker"

local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local util = require("lvim-preview.util")

local M = {}

-- Directory names never worth scanning.
local SKIP_DIR = {
    [".git"] = true,
    ["node_modules"] = true,
    [".venv"] = true,
    ["target"] = true,
    ["dist"] = true,
    [".cache"] = true,
}

--- Icon glyph for a path via lvim-icons, or the configured fallback.
---@param path string
---@return string
local function icon_for(path)
    local ok, icons = pcall(require, "lvim-icons")
    if ok then
        local res = icons.get(path)
        if res and res.glyph and res.glyph ~= "" then
            return res.glyph
        end
    end
    return (config.icons and config.icons.file) or ""
end

--- Scan the root for previewable files (bounded depth, skipping heavy/hidden dirs).
---@param root string
---@return { label: string, path: string }[]
local function scan(root)
    -- Derived from the ONE extension→kind map, gated by config.filetypes: a file the picker
    -- offers is by construction a file `preview_file` and the HTTP router will accept.
    local exts = util.enabled_exts()
    local out = {}
    local ok = pcall(function()
        for name, kind in vim.fs.dir(root, { depth = 8 }) do
            if kind == "file" then
                local ext = name:match("%.([%w]+)$")
                if ext and exts[ext:lower()] then
                    -- name is root-relative already (vim.fs.dir with depth returns nested paths)
                    local top = name:match("^([^/]+)/")
                    -- Dotfiles follow `serve_hidden` — the ONE switch for both sides, so what the
                    -- picker offers is always what the server will serve. A hidden segment counts
                    -- ANYWHERE in the path: the old test (`/%.`) only saw a dot AFTER a slash, so a
                    -- top-level hidden dir (`.github/README.md`) slipped into the list and 404'd.
                    local hidden = name:match("^%.") ~= nil or name:match("/%.") ~= nil
                    if not (top and SKIP_DIR[top]) and (config.serve_hidden or not hidden) then
                        out[#out + 1] = { label = name, path = vim.fs.normalize(root .. "/" .. name) }
                    end
                end
            end
        end
    end)
    if not ok then
        return out
    end
    table.sort(out, function(a, b)
        return a.label < b.label
    end)
    return out
end

--- Open the pick chooser. `on_choose(path)` is called with the selected absolute path.
---@param root string
---@param on_choose fun(path: string)
---@return nil
function M.pick(root, on_choose)
    local files = scan(root)
    if #files == 0 then
        vim.notify("lvim-preview: no previewable files under " .. root, vim.log.levels.WARN)
        return
    end

    ---@type table[]
    local items = {}
    local current_item = nil
    for i, f in ipairs(files) do
        items[i] = { label = f.label, icon = icon_for(f.path), path = f.path }
        -- Focus a file that is ALREADY previewed (any of them — several can be live at once).
        if state.doc(vim.fs.normalize(f.path)) then
            current_item = current_item or items[i]
        end
    end

    require("lvim-ui").select({
        title = ((config.icons and config.icons.pick) or "") .. " Preview file",
        items = items,
        current_item = current_item,
        callback = function(confirmed, index)
            if confirmed and index and items[index] then
                on_choose(items[index].path)
            end
        end,
    })
end

return M
