-- lvim-preview.config: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it IN PLACE (via
-- lvim-utils.utils.merge), so every `require("lvim-preview.config")` reader sees the
-- effective values. There is no separate runtime state here — session state (the running
-- server, connected clients, the previewed file) lives in `lvim-preview.state`; this table
-- is only the knobs the user turns.
--
---@module "lvim-preview.config"

---@class LvimPreviewIcons
---@field server string  the "serving" glyph (hud chip + status)
---@field file   string  fallback document glyph (lvim-icons wins per file when present)
---@field pick   string  the picker title glyph

---@class LvimPreviewMarkdownFeature
---@field typographer boolean  `(c)` → ©, `--` → –, `...` → …, straight quotes → curly
---@field linkify     boolean  turn bare `https://…`, `www.…` and email addresses into links
---@field task_lists  boolean  render `- [ ]` / `- [x]` as a disabled checkbox item
---@field emoji       boolean  turn `:shortcode:` into its emoji glyph (full GitHub set)
---@field footnotes   boolean  `[^ref]` + `[^ref]:` definitions → a superscript link + an end list

---@class LvimPreviewOrgFeature
---@field todo_keywords string[]  Keyword set the org parser treats as TODO states.

---@class LvimPreviewFeatures
---@field katex        boolean  render `$…$` / `$$…$$` math with KaTeX
---@field katex_macros table<string, string>  name → expansion, passed to KaTeX auto-render
---@field katex_mhchem boolean  load the vendored mhchem contrib (`\ce{…}` chemistry)
---@field mermaid      boolean  render ```mermaid fences as diagrams
---@field highlight    boolean  syntax-highlight fenced code blocks (highlight.js)
---@field markdown     LvimPreviewMarkdownFeature  markdown renderer options
---@field org          LvimPreviewOrgFeature  org renderer options

---@class LvimPreviewSyncScrollBack
---@field enabled  boolean  Master gate for the BROWSER→EDITOR direction. On by default.
---@field move     "view"|"cursor"  What a page scroll moves: the window's view (the cursor stays
---                                  where you left it) or the cursor itself.
---@field place    "top"|"center"   Where the reported line lands in the window.
---@field throttle integer  ms between two scroll reports from one page.
---@field settle   integer  ms one side keeps ownership of the sync after it moved the other.

---@class LvimPreviewArtifactPdf
---@field restore_position boolean  keep page / scroll / zoom across a producer reload
---@field highlight_ms     integer  ms a forward-search highlight rect stays visible
---@field lazy             boolean  render a page only as it nears the viewport (an
---                                 IntersectionObserver over per-page placeholders), releasing far
---                                 canvases — so a 500-page PDF never holds 500 canvases. Off =
---                                 rasterise every page up front and keep it.
---@field lookahead        integer  pages beyond the viewport (each side) kept painted, so the page
---                                 just below the fold is ready before it scrolls in. Lazy only.
---@field max_canvases     integer  most painted-page canvases retained at once (the nearest to the
---                                 viewport win); the rest are released and re-rendered on return.
---                                 Keep it ≥ the on-screen page count + 2 × lookahead. Lazy only.

---@class LvimPreviewExportConfig
---@field dir   string?  Directory the exported .html is written to. nil = beside the source file.
---@field embed "auto"|"all"  Which vendored libraries to inline. "auto" (default) inlines ONLY the
---                            libraries the document actually uses (a plain note stays tens of KB);
---                            "all" force-inlines every feature-enabled library (for a document that
---                            builds its diagrams/math dynamically after load).

---@class LvimPreviewArtifactConfig
---@field prefix                string   reserved URL namespace for registered artifacts
---@field allow_client_messages boolean  master gate for INBOUND viewer messages (inverse search)
---@field watch_debounce        integer  ms, only for artifacts registered with `watch = true`
---@field stall_note_ms         integer  ms before the viewer notes a build is still running
---@field pdf                   LvimPreviewArtifactPdf  pdf.js viewer behaviour

--- The palette-derived detail for `theme = "lvim"` (ignored by the fixed light/dark/auto themes).
--- Every colour is normally pulled LIVE from the editor — headings and code from the tree-sitter
--- highlight GROUPS the editor paints, base elements from named palette fields — so the preview is
--- literally the editor's colours and tracks a `:colorscheme` change. Each field here is an OVERRIDE:
--- a `#rrggbb` (or, for `code`/`heading_groups`, a highlight-group name) that replaces the live value.
---@class LvimPreviewThemeLvim
---@field headings       (string|false)[]  Per-level heading text colour, h1..h6. A `#rrggbb` pins the
---                                         level; nil (the default, all six) derives it from the editor's
---                                         markdown heading highlight (`heading_groups[N]`, i.e. the
---                                         palette rainbow), so the six levels read as a hierarchy.
---@field heading_groups string[]           The tree-sitter group each heading level derives from when not
---                                         pinned above (h1..h6). Default = `@markup.heading.N.markdown`.
---@field code           table<string,string>  hljs code-token class → tree-sitter group. The colour is
---                                         pulled LIVE from that group, so a `hljs-<x>` span gets the
---                                         SAME colour the editor gives the mapped capture. Remap a value
---                                         to a different group to recolour that token class. See the
---                                         mapping table in theme.lua for which hljs selectors each key
---                                         drives and its palette fallback.
---@field link           string?  Link colour. Default = palette `blue`.
---@field quote_fg       string?  Blockquote text. Default = palette `comment`.
---@field quote_border   string?  Blockquote left border. Default = palette `purple`.
---@field code_bg        string?  Inline-code / code-block background. Default = palette `bg_dark`.
---@field code_fg        string?  Inline-code / code-block base text. Default = palette `fg`.
---@field table_header_bg string? Table header-row background. Default = a blue tint of the page bg.
---@field table_alt_bg   string?  Even table-row background. Default = a faint blue tint of the page bg.
---@field table_border   string?  Table + heading-rule border. Default = palette `bg_highlight`.
---@field selection      string?  Text selection background. Default = a blue tint of the page bg.

---@class LvimPreviewLan
---@field warn boolean  On a non-loopback start, emit a loud WARN with the no-auth note + the URL(s).
---@field qr   boolean  On a non-loopback start, also pop the scannable QR window (`:LvimPreview qr`).

---@class LvimPreviewTunnel
---@field enabled     boolean   Spawn `cmd` on start and use the public URL it prints (no manual copy).
---@field cmd         string[]  argv of a command that forwards the LOCAL server to a PUBLIC URL and
---                             prints that URL; runs for the server's life. `{port}` is replaced with
---                             the actual bound port. Default = localhost.run over ssh (zero install).
---@field url_pattern string    Lua pattern matched against the command's output to capture the URL.

---@class LvimPreviewConfig
---@field address    string          Bind address. Non-loopback (LAN) is an explicit act — health warns.
---@field port       integer         Preferred TCP port.
---@field auto_port  boolean         Scan upward from `port` when it is busy.
---@field browser    string|string[]|nil  nil = system opener; a command string or an argv list.
---@field auto_open  boolean         Open the browser on `:LvimPreview start`.
---@field public_url string?         An explicit externally-reachable base URL (scheme://host[:port])
---                                   the preview sits behind — a tunnel (cloudflared / ngrok) or a
---                                   forwarded public IP. When set, the QR, `:LvimPreview qr`, the
---                                   start notice and `status` advertise THIS (+ the document path)
---                                   instead of the LAN / loopback address, and a start announces it
---                                   even on a loopback bind (the usual tunnel setup). nil = derive
---                                   from the bind. The plugin never auto-discovers a public IP — that
---                                   needs an external service and breaks the offline guarantee; you
---                                   set it to exactly what you exposed.
---@field root       string          "project" | "file" | an explicit absolute path.
---@field serve      "root"|"documents"  What the server exposes. "root" (default) serves any file
---                                   under `root` (needed for a project's cross-links, but it means
---                                   every file under root is readable by anything that reaches the
---                                   port). "documents" serves ONLY the previewed files plus the local
---                                   sub-resources they reference (images…), 404 for anything else —
---                                   the safe choice when the bind is non-loopback / behind a tunnel.
---@field serve_hidden boolean       Serve dotfiles under the root (ON — a project's docs often live in
---                                   a dot-dir; the server is loopback-only, and `.env`/`.git` become
---                                   readable by anything on this machine, so set false to lock it down).
---@field lan        LvimPreviewLan  What `start` does when `address` is non-loopback (LAN-exposed).
---@field tunnel     LvimPreviewTunnel  Optional auto-tunnel: run a command that prints a public URL,
---                                   capture it, advertise it in the QR / status (see tunnel.lua).
---@field debounce   integer         ms of idle before a type-driven push (md/org).
---@field sync_scroll boolean        Editor→browser scroll sync (md/org).
---@field sync_scroll_back LvimPreviewSyncScrollBack  Browser→editor scroll sync (md/org), on by default.
---@field theme      "lvim"|"light"|"dark"|"auto"  Preview theme; "lvim" tracks the live palette.
---@field theme_lvim LvimPreviewThemeLvim  Palette-derived detail for the "lvim" theme (headings + code).
---@field filetypes  string[]        Render kinds enabled for preview — the gate for the picker,
---                                   `preview_file` AND the HTTP router (see util.EXT_KIND).
---@field features   LvimPreviewFeatures  Client-side render toggles.
---@field export     LvimPreviewExportConfig  `:LvimPreview export` — static single-file HTML snapshot.
---@field artifact   LvimPreviewArtifactConfig  Producer-registered build artifacts (see artifact.lua).
---@field hud_chip   boolean         Show the lvim-hud serving chip while the server runs.
---@field notify     boolean         Emit start/stop/port/client vim.notify events.
---@field icons      LvimPreviewIcons Nerd Font single-width glyphs.

---@type LvimPreviewConfig
return {
    -- Loopback only by default. Binding any other address exposes the preview (and every
    -- file under the root) to the LAN with NO authentication — an explicit, deliberate act;
    -- health.lua warns whenever the bound address is non-loopback.
    address = "127.0.0.1",
    port = 5500,
    auto_port = true,
    -- Only relevant when `address` is non-loopback (you deliberately bind the LAN, e.g. to open the
    -- preview on a phone). A loopback bind is silent — nothing here fires. `warn` surfaces the no-auth
    -- exposure loudly at start (not only in :checkhealth) with the reachable URL(s); `qr` also pops a
    -- scannable QR of that URL so a phone opens the preview without typing an IP (`:LvimPreview qr`
    -- shows it on demand at any time). Both default on, so exposing the LAN is never silent.
    lan = { warn = true, qr = true },
    -- Optional auto-tunnel. With `enabled = true`, start spawns `cmd` (a process that forwards this
    -- loopback server to a PUBLIC address and prints that URL — the default is localhost.run over ssh,
    -- zero-install and anonymous), scrapes the URL with `url_pattern`, and advertises it in the QR /
    -- status / start notice — so you never copy-paste a dynamic address. The process lives for the
    -- server's life and is killed on stop / exit. `{port}` in `cmd` becomes the real bound port.
    -- Swap in cloudflared etc. by changing `cmd` + `url_pattern`. accept-new avoids ssh's first-run
    -- host-key prompt hanging the spawn (you may still need to accept localhost.run once by hand).
    -- CUSTOM DOMAIN: a named tunnel that always answers on the SAME address prints nothing to scrape —
    -- set `public_url` to your domain and it is used as-is (the process still runs for the connection);
    -- `url_pattern` is then ignored. e.g. cmd = { "cloudflared", "tunnel", "run", "--url",
    -- "http://localhost:{port}", "<name>" } with public_url = "https://preview.yourdomain.com".
    tunnel = {
        enabled = false,
        cmd = { "ssh", "-o", "StrictHostKeyChecking=accept-new", "-R", "80:localhost:{port}", "localhost.run" },
        url_pattern = "https://[%w.%-]+%.lhr%.life",
    },
    -- nil → the platform opener (xdg-open / open / start). A string is split on spaces;
    -- an argv list ({ "firefox", "--new-window" }) is passed verbatim to vim.system (never
    -- a shell string), so paths with spaces are safe.
    browser = nil,
    auto_open = true,
    -- Set to your tunnel / forwarded public base URL (e.g. "https://preview.example.com" or
    -- "http://203.0.113.5:5500") to advertise THAT in the QR / status / start notice. nil = derive
    -- from the bind (LAN IP when exposed, else loopback). Never auto-discovered — you set what you opened.
    public_url = nil,
    -- "project" — the project root (nearest ancestor with a root marker, else cwd); the whole
    --   tree is servable so relative links / images / css / js all resolve.
    -- "file" — the previewed file's own directory (re-rooted when the previewed file changes).
    -- "/abs/path" — an explicit servable root.
    root = "project",
    -- "root" = serve any file under `root` (a project's docs cross-link freely, but every file under
    -- root is readable by whatever reaches the port). "documents" = an allowlist: only the previewed
    -- files and the local sub-resources they reference (images…) are served, everything else 404s —
    -- the lockdown for a non-loopback / tunnelled bind, so exposure never means "the whole tree".
    serve = "root",
    serve_hidden = true,
    debounce = 100,
    sync_scroll = true,
    -- The WAY BACK: scrolling the PAGE scrolls the editor. On by default, and separately gated
    -- from `artifact.allow_client_messages` — this is the second, equally narrow relaxation of
    -- "the browser is a passive viewer", and the server accepts exactly one message shape for it.
    sync_scroll_back = {
        enabled = true,
        -- "view" — scroll the WINDOW and leave the cursor where you left it (scrolling is reading,
        --   not editing). The cursor is only dragged along when the new view no longer contains
        --   it, exactly as CTRL-E / CTRL-Y drag it.
        -- "cursor" — put the cursor on the reported line as well.
        move = "view",
        -- "top" — the reported line becomes the top window line. That is the SAME reference point
        --   the page reports (the source line at the top of the viewport) and the same one the
        --   editor sends outward (`line("w0")`), so a round trip is a fixed point and the two
        --   directions cannot chase each other. "center" is `zz`-like and is a deliberate
        --   asymmetry — only the settle window below keeps it stable.
        place = "top",
        -- ms between two reports while a page scroll is in flight (a scroll event fires per frame).
        throttle = 80,
        -- ms one side OWNS the sync after it moved the other; movement from the other side is
        -- ignored for that long. See scroll.lua for why this value.
        settle = 300,
    },
    theme = "lvim",
    -- Palette-derived detail for theme = "lvim" (the fixed light/dark/auto themes ignore it). The
    -- whole point is that NOTHING here is a hardcoded colour: headings and code tokens are pulled
    -- LIVE from the tree-sitter highlight GROUPS the editor paints, and base elements from named
    -- palette fields — so the preview is the editor's own colours and follows a :colorscheme change.
    -- Each field is an OVERRIDE that pins a value; leave it nil to keep tracking the editor.
    theme_lvim = {
        -- Per-level heading text colour, h1..h6. nil (all six) → derive from the editor's markdown
        -- heading highlight (heading_groups[N] — the palette rainbow), so the levels read as a
        -- hierarchy. Set any entry to a "#rrggbb" to pin that level.
        headings = { nil, nil, nil, nil, nil, nil },
        -- The tree-sitter group each level derives from when not pinned above. These are exactly the
        -- groups the editor uses to colour markdown headings, so a preview heading equals the editor.
        heading_groups = {
            "@markup.heading.1.markdown",
            "@markup.heading.2.markdown",
            "@markup.heading.3.markdown",
            "@markup.heading.4.markdown",
            "@markup.heading.5.markdown",
            "@markup.heading.6.markdown",
        },
        -- hljs code-token class → tree-sitter group. highlight.js tags code spans with `hljs-*`
        -- classes; each key here maps a class of token to the editor capture whose colour it should
        -- take, pulled LIVE (so `hljs-keyword` is the same colour as `@keyword` in your buffer).
        -- highlight.js is coarser than tree-sitter, so several classes fold onto the nearest capture
        -- (built_in → @function.builtin, literal → @constant.builtin, attr → @property, …). WHICH
        -- hljs selectors each key drives, and its palette fallback, is the CODE_SPEC table in theme.lua.
        code = {
            keyword = "@keyword",
            func = "@function",
            builtin = "@function.builtin",
            type = "@type",
            variable = "@variable",
            variable_builtin = "@variable.builtin",
            property = "@property",
            string = "@string",
            regexp = "@string.regexp",
            number = "@number",
            literal = "@constant.builtin",
            symbol = "@constant",
            comment = "@comment",
            operator = "@operator",
            punctuation = "@punctuation.delimiter",
            meta = "@keyword.directive",
            tag = "@tag",
            selector = "@variable",
            section = "@markup.heading",
            bullet = "@markup.list",
            addition = "@diff.plus",
            deletion = "@diff.minus",
        },
        -- Base document elements. nil → the palette default shown; a "#rrggbb" pins it.
        link = nil, -- palette blue
        quote_fg = nil, -- palette comment
        quote_border = nil, -- palette purple
        code_bg = nil, -- palette bg_dark
        code_fg = nil, -- palette fg
        table_header_bg = nil, -- blue tint of the page bg
        table_alt_bg = nil, -- faint blue tint of the page bg
        table_border = nil, -- palette bg_highlight
        selection = nil, -- blue tint of the page bg
    },
    -- The render KINDS (not extensions) this plugin will preview. Removing one makes every file
    -- that maps to it non-previewable everywhere at once — the picker stops offering it,
    -- `:LvimPreview start` refuses it, and the HTTP router stops wrapping it in the shell.
    -- The extension→kind map itself is util.EXT_KIND.
    filetypes = { "markdown", "org" },
    features = {
        katex = true,
        -- name → expansion, handed to KaTeX auto-render, e.g. { ["\\RR"] = "\\mathbb{R}" }.
        katex_macros = {},
        -- Chemistry (`\ce{H2O}`) via the vendored KaTeX mhchem contrib. Off by default: it is
        -- another ~60 KB on every page and only a minority of documents want it.
        katex_mhchem = false,
        mermaid = true,
        highlight = true,
        markdown = {
            -- The two passes that are NOT CommonMark: both were on in the renderer this one
            -- replaced, so both default on. Turn them off to see exactly what you typed.
            typographer = true,
            linkify = true,
            -- GFM task lists. Off by default because the previous renderer did not have them:
            -- switching it on changes `- [ ] todo` from literal text into a rendered checkbox.
            task_lists = false,
            -- `:shortcode:` emoji (the full GitHub set). On by default: the old markdown-it pipeline
            -- rendered it via markdown-it-emoji, so restoring it closes a regression. An unknown
            -- name is left VERBATIM (`:not_an_emoji:` stays literal); off = every `:shortcode:` stays
            -- literal too.
            emoji = true,
            -- Footnotes: a `[^label]` reference becomes a superscript link, and the matching
            -- `[^label]: …` definition collects into an ordered list at the document end with a
            -- back-link. On by default so markdown matches org, which has footnotes. A reference with
            -- no definition stays literal; an unreferenced definition is dropped (both like GitHub).
            footnotes = true,
        },
        org = {
            -- The one thing org readers really customise; everything else rides the flags above.
            todo_keywords = { "TODO", "DONE" },
        },
    },
    -- Static export: `:LvimPreview export [path]` writes the current markdown/org buffer to ONE
    -- self-contained .html file that opens offline — the rendered body, the theme, and every
    -- vendored library it uses (with KaTeX's fonts as data: URIs) inlined. It is a SNAPSHOT: no
    -- server, no live update, no scroll sync.
    export = {
        -- nil → write beside the source file (basename.html). A directory path writes there instead.
        dir = nil,
        -- "auto" — inline ONLY the libraries the document actually uses (KaTeX only with math,
        --   Mermaid only with a diagram, highlight.js only with a fenced code block), so a plain
        --   note is tens of KB instead of carrying ~3 MB of unused libraries. The decision reuses
        --   template.M.detect_use / M.assets, so it can never disagree with the live page.
        -- "all" — force every feature-enabled library in, for a document that builds its content
        --   dynamically after load (a diagram assembled by client script, math added by hand).
        embed = "auto",
    },
    -- Build ARTIFACTS: a file some OTHER plugin produced (a compiled PDF, a generated HTML)
    -- that this server displays and live-reloads on the producer's signal. See artifact.lua —
    -- nothing here is used until a producer calls `register_artifact`.
    artifact = {
        -- Reserved URL namespace; never collides with a document path under the servable root.
        prefix = "/@lvim-artifact/",
        -- MASTER gate for inbound viewer→editor messages (inverse search). OFF: the page stays
        -- the passive viewer it is for every ordinary preview. Even ON, a message is delivered
        -- only to an artifact whose producer supplied an `on_message` handler.
        allow_client_messages = false,
        watch_debounce = 100,
        stall_note_ms = 10000,
        pdf = {
            restore_position = true,
            highlight_ms = 1200,
            -- Lazy page rendering: a page is rasterised only as it nears the viewport and its
            -- canvas is released again when it scrolls far away, so an arbitrarily long PDF (a
            -- 500-page thesis) never holds hundreds of canvases in memory. Every page still gets a
            -- correctly-sized placeholder on load, so scroll position, restore and forward-search
            -- address a stable layout whether or not a page is painted. false = the old behaviour:
            -- rasterise every page up front and keep them all.
            lazy = true,
            -- Pages beyond the viewport (each direction) painted ahead, so the page just below the
            -- fold is ready before it is scrolled into view. 0 = paint strictly what is visible.
            lookahead = 1,
            -- Cap on retained canvases. When more than this are painted, the ones farthest from the
            -- viewport are released (re-rendered on return). Keep ≥ on-screen pages + 2 × lookahead
            -- so nothing visible is ever evicted; the default comfortably covers a full-height page.
            max_canvases = 8,
        },
    },
    hud_chip = true,
    notify = true,
    icons = {
        server = "", -- nf-fa-server
        file = "󰈙", -- nf-md-file_document
        pick = "", -- nf-fa-search
    },
}
