-- lvim-preview.template: the HTML shell served for a previewed document, and the reload-hook
-- injection for authored HTML pages. Pure string assembly — it is called from the fast HTTP
-- callback, so it reads only cached data (the theme CSS lives in state.theme_css, rebuilt on
-- the main thread) and never touches the editor or the palette live.
--
-- The shell loads, IN ORDER (all `defer`, so they execute after parse in document order):
-- the vendored render libs the document kind + feature flags call for, then our client.js
-- (last), which does the actual markdown-it / asciidoctor render, KaTeX / Mermaid / highlight
-- passes, and the WebSocket dispatch. The initial document text is embedded as a JSON string in
-- a typed <script> block (so `</script>` in the content can't break out), and a small config
-- block tells client.js the kind, the enabled features and the theme mode.
--
---@module "lvim-preview.template"

local config = require("lvim-preview.config")
local state = require("lvim-preview.state")

local M = {}

-- Static-asset URL prefix (mirrors server.http's STATIC_PREFIX).
local P = "/@lvim-preview/"

--- A <script defer src>… line for a plugin static asset.
---@param rel string
---@return string
local function script(rel)
    return ('<script defer src="%s%s"></script>'):format(P, rel)
end

--- A <link rel=stylesheet> line for a plugin static asset.
---@param rel string
---@return string
local function stylesheet(rel)
    return ('<link rel="stylesheet" href="%s%s">'):format(P, rel)
end

--- Embed `content` as a JSON string in a typed script block that JS reads and parses. The
--- `</` → `<\/` escape keeps a literal `</script>` inside the document from ending the block.
---@param content string
---@return string
local function initial_block(content)
    local json = vim.json.encode(content):gsub("</", "<\\/")
    return ('<script id="lp-initial" type="application/json">%s</script>'):format(json)
end

--- Build the full HTML shell for a previewable document.
---@param kind "markdown"|"asciidoc"|"svg"  the render kind
---@param content string                    the document text (may be unsaved buffer content)
---@param urlpath string                    the document's URL path (for the client's path check)
---@return string html
function M.shell(kind, content, urlpath)
    local features = config.features or {}
    local head = {
        '<meta charset="UTF-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">',
        "<title>lvim-preview</title>",
    }
    local body_class = "lp-body markdown-body"

    if kind == "markdown" or kind == "asciidoc" then
        head[#head + 1] = stylesheet("vendor/github-markdown-css/github-markdown.css")
        if features.highlight then
            head[#head + 1] = stylesheet("vendor/highlight/github.min.css")
            head[#head + 1] = stylesheet("vendor/highlight/github-dark.min.css")
        end
        if features.katex then
            head[#head + 1] = stylesheet("vendor/katex/katex.min.css")
        end
    end
    if kind == "asciidoc" then
        head[#head + 1] = stylesheet("vendor/asciidoctor/asciidoctor.min.css")
    end
    -- Our base layout + the live theme variables (last, so they override the vendored CSS).
    head[#head + 1] = stylesheet("style.css")
    head[#head + 1] = ('<style id="lp-theme">%s</style>'):format(state.theme_css or "")

    -- Render libraries, gated by kind + features.
    if kind == "markdown" then
        head[#head + 1] = script("vendor/markdown-it/markdown-it.min.js")
        if features.emoji then
            head[#head + 1] = script("vendor/markdown-it/markdown-it-emoji.min.js")
        end
    elseif kind == "asciidoc" then
        head[#head + 1] = script("vendor/asciidoctor/asciidoctor.min.js")
    end
    if (kind == "markdown" or kind == "asciidoc") and features.highlight then
        head[#head + 1] = script("vendor/highlight/highlight.min.js")
    end
    if (kind == "markdown" or kind == "asciidoc") and features.katex then
        head[#head + 1] = script("vendor/katex/katex.min.js")
        head[#head + 1] = script("vendor/katex/contrib/auto-render.min.js")
    end
    if kind == "markdown" and features.mermaid then
        head[#head + 1] = script("vendor/mermaid/mermaid.min.js")
    end

    -- Client config + initial content, then our dispatcher (deferred → runs after the libs).
    local cfg = vim.json.encode({
        kind = kind,
        path = urlpath,
        features = {
            katex = features.katex == true,
            mermaid = features.mermaid == true,
            highlight = features.highlight == true,
            emoji = features.emoji == true,
        },
    })
    head[#head + 1] = ("<script>window.__lvimPreview = %s;</script>"):format(cfg)
    head[#head + 1] = initial_block(content)
    head[#head + 1] = script("client.js")

    return table.concat({
        "<!DOCTYPE html>",
        '<html lang="en">',
        "<head>",
        table.concat(head, "\n"),
        "</head>",
        ('<body><article class="%s" id="lp-content"></article></body>'):format(body_class),
        "</html>",
    }, "\n")
end

--- Inject the WebSocket reload client into an authored HTML page so it refreshes on save. The
--- config + client scripts go just before </head> when present, else at the very top.
---@param html string
---@return string
function M.inject_reload(html)
    local inject = ("<script>window.__lvimPreview = %s;</script>\n%s"):format(
        vim.json.encode({ kind = "html" }),
        script("client.js")
    )
    if html:find("</head>") then
        return (html:gsub("</head>", inject .. "\n</head>", 1))
    end
    return inject .. "\n" .. html
end

return M
