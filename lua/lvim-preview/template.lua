-- lvim-preview.template: the HTML shells served by this plugin — the document shell, the PDF
-- artifact viewer, and the reload-hook injection for authored HTML pages. Pure string assembly:
-- it is called from the fast HTTP callback, so it reads only cached data (the theme CSS lives in
-- state.theme_css, rebuilt on the main thread) and never touches the editor or the palette live.
--
-- The document shell loads, IN ORDER (all `defer`, so they execute after parse in document
-- order): the vendored render libs the document kind + feature flags call for, then our
-- client.js (last), which places or renders the payload and runs the KaTeX / Mermaid /
-- highlight passes and the WebSocket dispatch. The initial payload is embedded as a JSON string
-- in a typed <script> block (so `</script>` in the content can't break out), and a small config
-- block tells client.js the kind, the enabled features and the theme mode.
--
-- markdown and org are the exceptions, and `M.server_render` is where it happens: both parsers and
-- both HTML renderers are OURS (lua/lvim-preview/markdown/, lua/lvim-preview/org/), so those pages
-- load no render library at all and the embedded payload is finished HTML rather than the document.
-- `server_rendered` in the config block is what tells the client which of the two it got. AsciiDoc
-- is the only kind still rendered in the browser.
--
-- The PDF shell is the same skeleton for a produced FILE instead of a buffer: pdf.js plus the
-- same client.js. pdf.js ships ESM only, so it is bootstrapped by an inline `type="module"`
-- block that hangs the namespace on `window.pdfjsLib` and fires an event — module scripts and
-- deferred classic scripts execute in document order, so client.js still sees it, and the event
-- covers the case where it does not.
--
---@module "lvim-preview.template"

local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local markdown = require("lvim-preview.markdown")
local org = require("lvim-preview.org")

local M = {}

--- Server-side render for the kinds this plugin renders in LUA rather than in the browser.
---
--- markdown and org: both parsers are ours (lua/lvim-preview/markdown/, lua/lvim-preview/org/), so
--- the page receives finished HTML instead of a document and a vendored parser to run on it. Only
--- AsciiDoc still renders client-side. `watch.lua` runs the same function for the `update` frames,
--- so first paint and every live update go through one code path and cannot disagree.
---@param kind string
---@param content string
---@return string?  the rendered HTML, or nil when the kind is rendered in the browser
function M.server_render(kind, content)
    local features = config.features or {}
    local ok, result
    if kind == "markdown" then
        local md_opts = features.markdown or {}
        ok, result = pcall(markdown.to_html, content, {
            source_lines = true,
            typographer = md_opts.typographer ~= false,
            linkify = md_opts.linkify ~= false,
            task_lists = md_opts.task_lists == true,
            tables = true,
            strike = true,
        })
    elseif kind == "org" then
        ok, result = pcall(org.to_html, content, {
            todo_keywords = (features.org or {}).todo_keywords,
            source_lines = true,
        })
    else
        return nil
    end
    if not ok then
        -- A parser bug must degrade to "the document, unstyled" — never to a blank page or a
        -- 500. The message is visible so it gets reported rather than silently tolerated.
        return ('<pre class="lp-parse-error">%s render failed: %s</pre>\n<pre>%s</pre>'):format(
            kind,
            org.html.escape(tostring(result)),
            org.html.escape(content)
        )
    end
    return result
end

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

--- The `features` block handed to client.js — only the flags the CLIENT actually reads. Options
--- that are decided server-side (which vendored scripts to load, the org TODO keyword set) are
--- deliberately not mirrored here: a config field on the page that nothing reads is dead surface.
---@return table
local function client_features()
    local features = config.features or {}
    return {
        katex = features.katex == true,
        -- vim.json encodes an empty Lua table as `[]`; the client only ever indexes it, and
        -- KaTeX accepts either, so no empty-dict dance is needed here.
        katex_macros = features.katex_macros or {},
        mermaid = features.mermaid == true,
        highlight = features.highlight == true,
    }
end

-- Prose kinds: rendered into the markdown-body article, sharing the same stylesheet set and the
-- same highlight / math / diagram post-passes.
---@type table<string, boolean>
local PROSE = { markdown = true, org = true }

--- Build the full HTML shell for a previewable document.
---@param kind "markdown"|"org"  the render kind
---@param content string                          the document text (may be unsaved buffer content)
---@param urlpath string                          the document's URL path (for the client's path check)
---@return string html
function M.shell(kind, content, urlpath)
    local features = config.features or {}
    local head = {
        '<meta charset="UTF-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">',
        "<title>lvim-preview</title>",
    }
    local body_class = "lp-body markdown-body"

    if PROSE[kind] then
        head[#head + 1] = stylesheet("vendor/github-markdown-css/github-markdown.css")
        if features.highlight then
            head[#head + 1] = stylesheet("vendor/highlight/github.min.css")
            head[#head + 1] = stylesheet("vendor/highlight/github-dark.min.css")
        end
        if features.katex then
            head[#head + 1] = stylesheet("vendor/katex/katex.min.css")
        end
    end
    -- Our base layout + the live theme variables (last, so they override the vendored CSS).
    head[#head + 1] = stylesheet("style.css")
    head[#head + 1] = ('<style id="lp-theme">%s</style>'):format(state.theme_css or "")

    -- Render libraries, gated by kind + features. markdown and org need NONE: they arrive already
    -- rendered (M.server_render), which is the whole point of owning both parsers.
    if PROSE[kind] and features.highlight then
        head[#head + 1] = script("vendor/highlight/highlight.min.js")
    end
    if PROSE[kind] and features.katex then
        head[#head + 1] = script("vendor/katex/katex.min.js")
        -- mhchem must load AFTER katex.min.js and BEFORE auto-render: it registers the `\ce`
        -- macro on the KaTeX instance the auto-render pass then uses.
        if features.katex_mhchem then
            head[#head + 1] = script("vendor/katex/contrib/mhchem.min.js")
        end
        head[#head + 1] = script("vendor/katex/contrib/auto-render.min.js")
    end
    -- Mermaid fences exist in markdown (```mermaid) and in org (#+BEGIN_SRC mermaid); both end
    -- up as <code class="language-mermaid">, which is what the client's mermaid pass selects.
    if (kind == "markdown" or kind == "org") and features.mermaid then
        head[#head + 1] = script("vendor/mermaid/mermaid.min.js")
    end

    -- Client config + initial content, then our dispatcher (deferred → runs after the libs).
    -- `server_rendered` tells client.js that the payload is finished HTML to place, not a
    -- document to render — which is now every kind except AsciiDoc and SVG.
    local rendered = M.server_render(kind, content)
    local back = config.sync_scroll_back or {}
    local cfg = vim.json.encode({
        kind = kind,
        path = urlpath,
        server_rendered = rendered ~= nil,
        features = client_features(),
        -- Present ONLY when the browser→editor direction is on. Its presence is what switches the
        -- client into two-way mode, so a page served while it is off can never report a scroll.
        sync_scroll_back = back.enabled == true and {
            throttle = math.max(0, back.throttle or 80),
            settle = math.max(0, back.settle or 300),
        } or nil,
    })
    head[#head + 1] = ("<script>window.__lvimPreview = %s;</script>"):format(cfg)
    head[#head + 1] = initial_block(rendered or content)
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

--- The client-config block for an ARTIFACT page: everything the viewer needs to refetch the
--- produced file and to react to `artifact` / `status` / `synctex` frames.
---@param art LvimPreviewArtifact
---@param kind string  the client render kind for this viewer
---@return string
local function artifact_cfg(art, kind)
    return ("<script>window.__lvimPreview = %s;</script>"):format(vim.json.encode({
        kind = kind,
        path = art.url_path,
        features = client_features(),
        artifact = {
            id = art.id,
            file = art.name,
            title = art.title,
            viewer = art.viewer,
            generation = art.generation,
            status = art.status.state,
            message = art.status.message,
            restore_position = config.artifact.pdf.restore_position == true,
            highlight_ms = config.artifact.pdf.highlight_ms,
            stall_ms = config.artifact.stall_note_ms,
            allow_client_messages = config.artifact.allow_client_messages == true,
        },
    }))
end

--- The pdf.js viewer page for a `viewer = "pdf"` artifact.
---@param art LvimPreviewArtifact
---@return string html
function M.pdf_shell(art)
    local head = {
        '<meta charset="UTF-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">',
        ("<title>%s</title>"):format((art.title:gsub("[<>&]", ""))),
        stylesheet("style.css"),
        ('<style id="lp-theme">%s</style>'):format(state.theme_css or ""),
        -- pdf.js is ESM-only upstream; this inline module is OURS, not a patched vendor file.
        table.concat({
            '<script type="module">',
            ('import * as pdfjsLib from "%svendor/pdfjs/pdf.min.mjs";'):format(P),
            ('pdfjsLib.GlobalWorkerOptions.workerSrc = "%svendor/pdfjs/pdf.worker.min.mjs";'):format(P),
            "window.pdfjsLib = pdfjsLib;",
            'window.dispatchEvent(new Event("lp-pdfjs"));',
            "</script>",
        }, "\n"),
        artifact_cfg(art, "pdf"),
        script("client.js"),
    }
    return table.concat({
        "<!DOCTYPE html>",
        '<html lang="en">',
        "<head>",
        table.concat(head, "\n"),
        "</head>",
        '<body class="lp-body lp-artifact"><div id="lp-pdf"></div><div id="lp-overlay" hidden></div></body>',
        "</html>",
    }, "\n")
end

--- The placeholder page for an artifact whose file does not exist yet (registered before the
--- first build). It carries the full client, so the `artifact` frame that follows the first
--- successful build reloads it into the real page.
---@param art LvimPreviewArtifact
---@return string html
function M.artifact_pending(art)
    return table.concat({
        "<!DOCTYPE html>",
        '<html lang="en">',
        "<head>",
        '<meta charset="UTF-8">',
        ("<title>%s</title>"):format((art.title:gsub("[<>&]", ""))),
        stylesheet("style.css"),
        ('<style id="lp-theme">%s</style>'):format(state.theme_css or ""),
        artifact_cfg(art, "html"),
        script("client.js"),
        "</head>",
        ('<body class="lp-body lp-artifact"><div id="lp-overlay" hidden></div><p class="lp-pending">%s has not been produced yet.</p></body>'):format(
            (art.name:gsub("[<>&]", ""))
        ),
        "</html>",
    }, "\n")
end

--- Inject the WebSocket reload client into an authored HTML page so it refreshes on save (a
--- previewed .html document) or on a producer signal (an `viewer = "html"` artifact). The config
--- + client scripts go just before </head> when present, else at the very top.
---@param html string
---@param art LvimPreviewArtifact?  when given, the page is that artifact's viewer
---@return string
function M.inject_reload(html, art)
    local cfg = art and artifact_cfg(art, "html")
        or ("<script>window.__lvimPreview = %s;</script>"):format(vim.json.encode({ kind = "html" }))
    local inject = cfg .. "\n" .. script("client.js")
    if html:find("</head>") then
        -- `%` is the escape character in a gsub REPLACEMENT string, and the injected JSON can
        -- legitimately contain one (a percent-encoded artifact path, a `%` in a title), which
        -- would otherwise raise "invalid use of '%' in replacement string".
        return (html:gsub("</head>", (inject:gsub("%%", "%%%%")) .. "\n</head>", 1))
    end
    return inject .. "\n" .. html
end

return M
