-- lvim-preview.export: `:LvimPreview export [path]` — write the current markdown/org buffer to ONE
-- self-contained .html file that opens OFFLINE. It is a SNAPSHOT of the document, not a live view:
-- no server, no WebSocket, no scroll sync. Everything the page needs is INLINED — the rendered body,
-- the base + theme CSS, and every vendored render library the document actually uses, with the
-- fonts those stylesheets reference embedded as `data:` URIs — so the file works from a `file://`
-- URL with no network at all.
--
-- The conditional part is the whole point: Mermaid alone is ~2.5 MB and KaTeX ~640 KB, so a plain
-- note must not carry them. WHICH libraries to inline is NOT decided here — it is decided by the
-- SAME selector the live page uses (template.M.assets, fed by template.M.detect_use), so the export
-- and the served page can never drift about what a document needs. `embed = "auto"` inlines only
-- what the content uses; `embed = "all"` forces every feature-enabled library in.
--
-- Two things the served page does with `<link>`/`<script src>` this file must do differently:
--   * fonts — a served stylesheet pulls its woff2 by relative URL; an offline file cannot, so every
--     `url(...)` in an inlined stylesheet is rewritten to a base64 `data:` URI (KaTeX ships woff2
--     only, its woff/ttf fallbacks are stripped so nothing dangles).
--   * hljs theme — the live page inlines BOTH github light+dark stylesheets and toggles `.disabled`
--     from JS; a static file has no server to re-theme it, so it snapshots the CURRENT theme and
--     inlines only the matching hljs stylesheet (or media-gates both under theme = "auto").
--
---@module "lvim-preview.export"

local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local util = require("lvim-preview.util")
local template = require("lvim-preview.template")
local theme = require("lvim-preview.theme")

local M = {}

-- The plugin's static/ directory, resolved from THIS file's path (mirrors server.http's STATIC_DIR)
-- — the export runs on the main thread, but resolving from source keeps it independent of the
-- server module's load state.
---@type string
local STATIC_DIR = (function()
    local this = debug.getinfo(1, "S").source:sub(2)
    return (vim.fs.normalize(this):gsub("/lua/lvim%-preview/export%.lua$", "/static"))
end)()

-- Extension → MIME for the data: URIs embedded into stylesheets. Only the types the vendored CSS
-- actually references (fonts + the odd inline image) need an entry.
---@type table<string, string>
local MIME = {
    woff2 = "font/woff2",
    woff = "font/woff",
    ttf = "font/ttf",
    otf = "font/otf",
    eot = "application/vnd.ms-fontobject",
    svg = "image/svg+xml",
    png = "image/png",
    jpg = "image/jpeg",
    jpeg = "image/jpeg",
    gif = "image/gif",
}

--- Read a file as text, or nil when it cannot be opened.
---@param path string
---@return string?
local function read_text(path)
    local fd = io.open(path, "r")
    if not fd then
        return nil
    end
    local data = fd:read("*a")
    fd:close()
    return data
end

--- Read a file as raw bytes, or nil.
---@param path string
---@return string?
local function read_binary(path)
    local fd = io.open(path, "rb")
    if not fd then
        return nil
    end
    local data = fd:read("*a")
    fd:close()
    return data
end

--- The absolute path of a vendor-relative asset (as named by template.M.assets).
---@param rel string
---@return string
local function static_path(rel)
    return STATIC_DIR .. "/" .. rel
end

--- A `data:<mime>;base64,<…>` URI for a binary asset, or nil when it cannot be read.
---@param path string
---@param mime string
---@return string?
local function data_uri(path, mime)
    local bytes = read_binary(path)
    if not bytes then
        return nil
    end
    return ("data:%s;base64,%s"):format(mime, vim.base64.encode(bytes))
end

--- Inline a vendored stylesheet: read it and rewrite every relative `url(...)` reference to a
--- self-contained `data:` URI, so the CSS carries its own fonts/images and the exported file needs
--- no sibling directory. `data:` and absolute URLs pass through untouched.
---
--- KaTeX is the one stylesheet with fallbacks we do not ship: each `@font-face` lists woff2 (which
--- we vendor) then woff + ttf (which we do NOT — they 404 even on the live server, where the browser
--- just uses the first supported format). Those two comma-joined fallbacks are stripped first, so
--- after inlining the woff2 nothing in the `src:` list points at a missing file.
---@param rel string  vendor-relative stylesheet path
---@return string css
local function inline_stylesheet(rel)
    local css = read_text(static_path(rel)) or ""
    local dir = static_path(rel):gsub("/[^/]*$", "") -- the stylesheet's own directory
    -- Drop the unshipped KaTeX fallback formats (comma-prefixed, so the woff2 before them survives).
    css = css:gsub(",%s*url%(fonts/[^)]+%.woff%)%s*format%(%s*[\"']?woff[\"']?%s*%)", "")
    css = css:gsub(",%s*url%(fonts/[^)]+%.ttf%)%s*format%(%s*[\"']?truetype[\"']?%s*%)", "")
    -- Embed every remaining relative url() as a data: URI.
    css = css:gsub("url%(([^)]+)%)", function(ref)
        local raw = ref:gsub("^%s*[\"']?", ""):gsub("[\"']?%s*$", "")
        if raw:match("^data:") or raw:match("^https?:") or raw:match("^//") then
            return "url(" .. ref .. ")"
        end
        local ext = raw:match("%.([%w]+)$")
        local mime = ext and MIME[ext:lower()]
        local uri = mime and data_uri(dir .. "/" .. raw, mime)
        if not uri then
            -- Unknown type or missing file: leave the reference as-is rather than break the CSS.
            return "url(" .. ref .. ")"
        end
        return "url(" .. uri .. ")"
    end)
    return css
end

--- The active hljs light/dark scheme, snapshotted from the cached theme CSS. Returns `is_auto`
--- true when the theme ships BOTH schemes (theme = "auto"): the export then media-gates the dark
--- stylesheet instead of picking one.
---@return string scheme  "light" | "dark"
---@return boolean is_auto
local function hljs_scheme()
    local css = state.theme_css or ""
    if css:find("prefers%-color%-scheme") then
        return "light", true
    end
    return (css:match("%-%-lp%-hljs:%s*(%w+)")) or "dark", false
end

--- The inlined hljs theme CSS for the snapshotted scheme. The live page toggles two `<link>`s from
--- JS; a static file has no server to do that, so it inlines only the matching stylesheet — or, for
--- theme = "auto", both with the dark half under a `prefers-color-scheme` media query.
---@return string css
local function hljs_stylesheet()
    local scheme, is_auto = hljs_scheme()
    local light = read_text(static_path("vendor/highlight/github.min.css")) or ""
    local dark = read_text(static_path("vendor/highlight/github-dark.min.css")) or ""
    if is_auto then
        return light .. "\n@media (prefers-color-scheme: dark) {\n" .. dark .. "\n}"
    end
    return scheme == "dark" and dark or light
end

--- Escape `<`, `>`, `&` for the document <title>.
---@param s string
---@return string
local function esc_title(s)
    return (s:gsub("[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

--- The self-contained boot script: run the highlight → mermaid → KaTeX passes on the already-placed
--- body once the page loads, and theme mermaid from `--lp-hljs`. It carries NO WebSocket and drives
--- nothing — the file is a snapshot. It mirrors client.js's post-passes exactly (same order, same
--- KaTeX delimiters + macros) so a static file typesets identically to the live page.
---@return string
local function boot_script()
    local macros = vim.json.encode(config.features.katex_macros or {})
    return ([[
(function () {
  "use strict";
  function scheme() {
    return getComputedStyle(document.documentElement).getPropertyValue("--lp-hljs").trim();
  }
  if (typeof mermaid !== "undefined") {
    mermaid.initialize({ startOnLoad: false, securityLevel: "loose", theme: scheme() === "dark" ? "dark" : "default" });
  }
  window.addEventListener("load", function () {
    // Look up the body element HERE, not at head-parse time: this script is inlined in <head>
    // (an inline script cannot `defer`), so the <article> does not exist until the load event.
    var content = document.getElementById("lp-content");
    if (!content) return;
    if (typeof hljs !== "undefined") {
      content.querySelectorAll("pre code:not(.language-mermaid)").forEach(function (el) {
        try { hljs.highlightElement(el); } catch (e) {}
      });
    }
    if (typeof mermaid !== "undefined") {
      try { mermaid.run({ querySelector: ".language-mermaid, .mermaid" }); } catch (e) {}
    }
    if (typeof renderMathInElement !== "undefined") {
      renderMathInElement(content, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "$", right: "$", display: false },
          { left: "\\(", right: "\\)", display: false },
          { left: "\\[", right: "\\]", display: true },
        ],
        macros: Object.assign({}, %s),
        throwOnError: false,
      });
    }
  });
})();
]]):format(macros)
end

--- Assemble the complete self-contained HTML for `kind`/`content`.
---@param kind string  "markdown"|"org"
---@param content string  the buffer text (unsaved edits included)
---@param title string
---@return string html
---@return { css: string[], js: string[] }  the vendored assets that were inlined (for the report)
function M.build_html(kind, content, title)
    theme.refresh() -- snapshot the current palette into state.theme_css
    local rendered = template.server_render(kind, content) or content

    -- WHICH libraries to inline — the shared selector, so export and the live page agree. embed =
    -- "auto" gates each on real use (detect_use); "all" passes use = nil to force every enabled one.
    local use = config.export.embed ~= "all" and template.detect_use(rendered) or nil
    local assets = template.assets(kind, { features = config.features, use = use })

    local head = {
        '<meta charset="UTF-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">',
        ("<title>%s</title>"):format(esc_title(title)),
    }
    -- Stylesheets, in the live shell's order. The two hljs github files are collapsed into one
    -- theme-snapshotted block (emitted when the light one is reached; the dark one is skipped).
    for _, rel in ipairs(assets.css) do
        if rel:find("highlight/github%-dark") then
            -- handled together with the light stylesheet below
        elseif rel:find("highlight/github%.min") then
            head[#head + 1] = ("<style>%s</style>"):format(hljs_stylesheet())
        else
            head[#head + 1] = ("<style>%s</style>"):format(inline_stylesheet(rel))
        end
    end
    -- Our base layout + the snapshotted theme variables (last, so they override the vendored CSS).
    head[#head + 1] = ("<style>%s</style>"):format(inline_stylesheet("style.css"))
    head[#head + 1] = ('<style id="lp-theme">%s</style>'):format(state.theme_css or "")
    -- The render libraries, inlined verbatim in load order, then our boot script.
    for _, rel in ipairs(assets.js) do
        head[#head + 1] = ("<script>%s</script>"):format(read_text(static_path(rel)) or "")
    end
    head[#head + 1] = ("<script>%s</script>"):format(boot_script())

    local html = table.concat({
        "<!DOCTYPE html>",
        '<html lang="en">',
        "<head>",
        table.concat(head, "\n"),
        "</head>",
        '<body><article class="lp-body markdown-body" id="lp-content">' .. rendered .. "</article></body>",
        "</html>",
    }, "\n")
    return html, assets
end

--- A human-readable byte count (for the success report — a 4 MB export vs a 50 KB one matters).
---@param n integer
---@return string
local function human_size(n)
    if n >= 1024 * 1024 then
        return ("%.1f MB"):format(n / (1024 * 1024))
    elseif n >= 1024 then
        return ("%.1f KB"):format(n / 1024)
    end
    return ("%d B"):format(n)
end

--- Resolve the output path from the optional `[path]` argument and the current source file.
--- Omitted → the source basename with `.html`, under `config.export.dir` when set, else beside the
--- source. A directory argument (existing dir or a trailing slash) writes the default name there.
---@param arg string?
---@param src string  absolute source path
---@return string out  absolute, normalised
local function resolve_out(arg, src)
    local base = vim.fn.fnamemodify(src, ":t:r") .. ".html"
    if arg and arg ~= "" then
        local p = vim.fs.normalize(vim.fn.fnamemodify(arg, ":p"))
        if arg:sub(-1) == "/" or vim.fn.isdirectory(p) == 1 then
            return p:gsub("/$", "") .. "/" .. base
        end
        return p
    end
    local dir = config.export.dir
    if dir and dir ~= "" then
        return vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/$", "") .. "/" .. base
    end
    return vim.fs.normalize(vim.fn.fnamemodify(src, ":h")) .. "/" .. base
end

--- Write `html` to `out` (creating parent dirs), then report the path + size.
---@param html string
---@param out string
---@return nil
local function write_file(html, out)
    vim.fn.mkdir(vim.fn.fnamemodify(out, ":h"), "p")
    local fd, err = io.open(out, "wb")
    if not fd then
        vim.notify("lvim-preview: cannot write " .. out .. ": " .. tostring(err), vim.log.levels.ERROR)
        return
    end
    fd:write(html)
    fd:close()
    vim.notify(
        ("lvim-preview: exported %s (%s)"):format(vim.fn.fnamemodify(out, ":~"), human_size(#html)),
        vim.log.levels.INFO
    )
end

--- Export the current buffer to a self-contained HTML file.
---@param arg string?  optional output path (file or directory)
---@return nil
function M.run(arg)
    local buf = vim.api.nvim_get_current_buf()
    local src = vim.api.nvim_buf_get_name(buf)
    if src == "" then
        vim.notify("lvim-preview: no file in the current buffer to export", vim.log.levels.WARN)
        return
    end
    local kind = util.kind_for(src)
    if not kind then
        vim.notify(
            ("lvim-preview: not a previewable (markdown/org) buffer: %s"):format(vim.fn.fnamemodify(src, ":t")),
            vim.log.levels.WARN
        )
        return
    end

    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    local title = vim.fn.fnamemodify(src, ":t")
    local html = M.build_html(kind, content, title)
    local out = resolve_out(arg, vim.fs.normalize(vim.fn.fnamemodify(src, ":p")))

    if vim.fn.filereadable(out) == 1 then
        -- Never clobber silently, and never a raw vim.ui — the canonical themed picker confirms.
        require("lvim-ui").select({
            title = ((config.icons and config.icons.file) or "")
                .. " Overwrite "
                .. vim.fn.fnamemodify(out, ":t")
                .. "?",
            items = { { label = "Overwrite" }, { label = "Cancel" } },
            callback = function(confirmed, index)
                if confirmed and index == 1 then
                    write_file(html, out)
                end
            end,
        })
        return
    end
    write_file(html, out)
end

return M
