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
-- markdown and org are the two document kinds, and `M.server_render` is where they render: both
-- parsers and both HTML renderers are OURS (lua/lvim-preview/markdown/, lua/lvim-preview/org/), so
-- those pages load no render library at all and the embedded payload is finished HTML rather than
-- the document. `server_rendered` in the config block tells the client the payload is finished HTML.
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

--- Server-side render for the document kinds this plugin renders in LUA.
---
--- markdown and org: both parsers are ours (lua/lvim-preview/markdown/, lua/lvim-preview/org/), so
--- the page receives finished HTML instead of a document and a vendored parser to run on it.
--- `watch.lua` runs the same function for the `update` frames, so first paint and every live update
--- go through one code path and cannot disagree.
---@param kind string
---@param content string
---@return string?  the rendered HTML, or nil for a kind this function does not render
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
            -- Default ON (closing the markdown-it-emoji / footnote regression); both are one flag
            -- fed to BOTH the parser and the renderer, so a reference and its list stay consistent.
            emoji = md_opts.emoji ~= false,
            footnotes = md_opts.footnotes ~= false,
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

--- Resolve a document-relative URL reference the way a browser would, against `base` (the document's
--- url-path). Root-absolute refs (`/x`) pass through; relative refs join the document's directory;
--- `.`/`..` segments collapse. Query and fragment are dropped. Pure string work.
---@param base string  the referring document's url-path, e.g. "/docs/readme.md"
---@param ref string   the raw reference from the HTML (an img src)
---@return string?     the resolved url-path, or nil when empty
local function resolve_ref(base, ref)
    ref = ref:gsub("[?#].*$", "")
    if ref == "" then
        return nil
    end
    local path = ref
    if ref:sub(1, 1) ~= "/" then
        path = base:gsub("[^/]*$", "") .. ref -- the document's directory (keeps the trailing slash)
    end
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then
            parts[#parts] = nil
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return "/" .. table.concat(parts, "/")
end

--- The set of LOCAL sub-resource url-paths a rendered document references — its `src` targets
--- (images and the like), resolved against `base_urlpath`. Absolute URLs (scheme:, //), anchors,
--- and the plugin's own static / artifact prefixes are excluded, so what remains is exactly the
--- files under the root the page will fetch. `serve = "documents"` mode allowlists these; a plain
--- string scan (we generate this HTML, so its shape is known) keeps it HTTP-callback safe.
---@param html string             rendered HTML (a document body, or the full shell page)
---@param base_urlpath string     the document's url-path, to resolve relative refs against
---@return table<string, true>    the referenced url-paths, as a set
function M.local_refs(html, base_urlpath)
    local refs = {}
    local art_p = (config.artifact and config.artifact.prefix) or ""
    local function consider(v)
        if not v or v == "" then
            return
        end
        if v:match("^%a[%w+.-]*:") or v:sub(1, 2) == "//" or v:sub(1, 1) == "#" then
            return -- scheme (http:/data:/mailto:…), protocol-relative, or a bare anchor
        end
        if v:sub(1, #P) == P or (#art_p > 0 and v:sub(1, #art_p) == art_p) then
            return -- the plugin's own static assets / registered artifacts, served elsewhere
        end
        local u = resolve_ref(base_urlpath, v)
        if u and u ~= base_urlpath then
            refs[u] = true
        end
    end
    for v in html:gmatch('src%s*=%s*"([^"]*)"') do
        consider(v)
    end
    for v in html:gmatch("src%s*=%s*'([^']*)'") do
        consider(v)
    end
    return refs
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

--- Which render libraries a rendered document ACTUALLY uses, found by scanning the finished HTML
--- for the exact markers the client's post-passes select — the SAME signal the browser acts on, so
--- a detection here can never disagree with what the live page would render. Used by the static
--- export to decide what to inline (a plain note must not carry KaTeX + Mermaid it never touches);
--- the live page does not detect, it links whatever the feature flags allow because its content
--- changes as you type.
---@class LvimPreviewAssetUse
---@field katex     boolean  math delimiters KaTeX auto-render scans for are present
---@field mermaid   boolean  a `language-mermaid` diagram fence is present
---@field highlight boolean  a fenced code block that is not a mermaid diagram is present
---@field mhchem    boolean  an mhchem macro (`\ce` / `\pu`) is present
---@param html string  the server-rendered HTML (M.server_render output)
---@return LvimPreviewAssetUse
function M.detect_use(html)
    html = html or ""
    -- mermaid renders `<code class="language-mermaid">`; highlight runs on every other `pre code`.
    local mermaid = html:find("language%-mermaid") ~= nil
    local highlight = false
    for attrs in html:gmatch("<pre[^>]*><code([^>]*)>") do
        if not attrs:find("language%-mermaid") then
            highlight = true
            break
        end
    end
    -- KaTeX auto-render ignores <pre>/<code> (its default ignoredTags), so a `$` inside a code
    -- block is NOT math on the page — strip those regions before scanning, exactly as the browser
    -- would, so a shell snippet with a `$PATH` does not drag KaTeX into a plain note.
    local prose = html:gsub("<pre.-</pre>", ""):gsub("<code.-</code>", "")
    -- $$…$$, \[ \] and \( \) are unambiguous. Inline `$…$` counts only with NO whitespace just
    -- inside the delimiters (the markdown-math convention) — this is DELIBERATELY stricter than
    -- KaTeX auto-render's own naive scanner, so a "$5 … $10" price list is left as prose (shown as
    -- text) instead of dragging 640 KB of KaTeX into a plain note to render junk math.
    local katex = prose:find("%$%$") ~= nil
        or prose:find("\\%[") ~= nil
        or prose:find("\\%(") ~= nil
        or prose:find("%$[^%s%$]%$") ~= nil
        or prose:find("%$[^%s%$][^%$]-[^%s%$]%$") ~= nil
    local mhchem = prose:find("\\ce") ~= nil or prose:find("\\pu") ~= nil
    return { katex = katex, mermaid = mermaid, highlight = highlight, mhchem = mhchem }
end

--- The ordered set of vendored render assets a page of this kind needs — the SINGLE place that
--- decides "this document links highlight.js / KaTeX / Mermaid", so the live shell and the static
--- export can never drift about it.
---
--- `opts.use` is the switch between the two callers: nil (the LIVE page and export `embed = "all"`)
--- links every library the feature flags enable, because live content may grow math later and a
--- forced export wants the libraries present unconditionally; a detection table (export `embed =
--- "auto"`, from `M.detect_use`) additionally gates each library on whether the CONTENT uses it.
---@param kind string
---@param opts { features: table?, use: LvimPreviewAssetUse? }?
---@return { css: string[], js: string[] }  vendor-relative paths, in load order
function M.assets(kind, opts)
    opts = opts or {}
    local features = opts.features or config.features or {}
    local use = opts.use
    -- A library is included when its feature is on AND (no detection, or the content uses it).
    local function on(feature)
        if not features[feature] then
            return false
        end
        return use == nil or use[feature] == true
    end
    local css, js = {}, {}
    if PROSE[kind] then
        css[#css + 1] = "vendor/github-markdown-css/github-markdown.css"
        -- The "lvim" theme generates its own `.hljs-*` colours from the editor's tree-sitter groups
        -- (theme.hljs_css, inlined in the <style id="lp-theme"> block), so it links NEITHER vendored
        -- github hljs stylesheet — they would only fight the generated CSS. The fixed light/dark/auto
        -- themes have no live palette to derive from, so they keep using the vendored pair, toggled
        -- by client.js. highlight.min.js is still linked either way — it TAGS the spans; only the
        -- colour source differs.
        if on("highlight") and config.theme ~= "lvim" then
            css[#css + 1] = "vendor/highlight/github.min.css"
            css[#css + 1] = "vendor/highlight/github-dark.min.css"
        end
        if on("katex") then
            css[#css + 1] = "vendor/katex/katex.min.css"
        end
        if on("highlight") then
            js[#js + 1] = "vendor/highlight/highlight.min.js"
        end
        if on("katex") then
            js[#js + 1] = "vendor/katex/katex.min.js"
            -- mhchem must load AFTER katex.min.js and BEFORE auto-render (it registers `\ce` on the
            -- KaTeX instance auto-render then uses). Feature-gated always; in detection mode it is
            -- dropped unless the document actually has a chemistry macro.
            if features.katex_mhchem and (use == nil or use.mhchem == true) then
                js[#js + 1] = "vendor/katex/contrib/mhchem.min.js"
            end
            js[#js + 1] = "vendor/katex/contrib/auto-render.min.js"
        end
        if on("mermaid") then
            js[#js + 1] = "vendor/mermaid/mermaid.min.js"
        end
    end
    return { css = css, js = js }
end

--- Build the full HTML shell for a previewable document.
---@param kind "markdown"|"org"  the render kind
---@param content string                          the document text (may be unsaved buffer content)
---@param urlpath string                          the document's URL path (for the client's path check)
---@return string html   the full page
---@return string? body  the server-rendered document HTML (nil if rendered client-side) — the caller
---                       harvests `local_refs` from THIS, not the page (the page embeds it as escaped
---                       JSON, where an `src="…"` scan would not match).
function M.shell(kind, content, urlpath)
    local features = config.features or {}
    local head = {
        '<meta charset="UTF-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">',
        "<title>lvim-preview</title>",
    }
    local body_class = "lp-body markdown-body"

    -- The vendored render libraries this page links — chosen by the shared selector (M.assets) so
    -- the live page and the static export can never disagree about what a document needs. The live
    -- page links whatever the feature flags allow (no content detection: its content changes live).
    -- markdown and org arrive already rendered (M.server_render), so they load NO parser here.
    local assets = M.assets(kind, { features = features })
    for _, rel in ipairs(assets.css) do
        head[#head + 1] = stylesheet(rel)
    end
    -- Our base layout + the live theme variables (last, so they override the vendored CSS).
    head[#head + 1] = stylesheet("style.css")
    head[#head + 1] = ('<style id="lp-theme">%s</style>'):format(state.theme_css or "")
    for _, rel in ipairs(assets.js) do
        head[#head + 1] = script(rel)
    end

    -- Client config + initial content, then our dispatcher (deferred → runs after the libs).
    -- `server_rendered` tells client.js that the payload is finished HTML to place, not a
    -- document to render — true for both document kinds (markdown and org).
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
    }, "\n"),
        rendered
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
            -- Lazy pdf rendering knobs (see config.artifact.pdf). The viewer paints pages on demand
            -- and caps retained canvases; these drive the IntersectionObserver in client.js.
            lazy = config.artifact.pdf.lazy ~= false,
            lookahead = config.artifact.pdf.lookahead ~= nil and config.artifact.pdf.lookahead or 1,
            max_canvases = config.artifact.pdf.max_canvases ~= nil and config.artifact.pdf.max_canvases or 8,
            stall_ms = config.artifact.stall_note_ms,
            allow_client_messages = config.artifact.allow_client_messages == true,
            -- Where in the viewport the page calls "here" when it reports its reading position, and
            -- the x it reports with it (see config.artifact.pdf).
            -- `or default` cannot serialise a deliberate ZERO, and zero is inside both domains: the
            -- top of the viewport, and the left edge of the page. The client's own
            -- `typeof … === "number"` handling is unreachable for those values unless the nil test
            -- is explicit here.
            scroll_anchor = config.artifact.pdf.scroll_anchor ~= nil and config.artifact.pdf.scroll_anchor or 0.5,
            scroll_x = config.artifact.pdf.scroll_x ~= nil and config.artifact.pdf.scroll_x or 40,
            scroll_throttle = config.artifact.pdf.scroll_throttle ~= nil and config.artifact.pdf.scroll_throttle or 80,
            scroll_settle = config.artifact.pdf.scroll_settle ~= nil and config.artifact.pdf.scroll_settle or 400,
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
