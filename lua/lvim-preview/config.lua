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

---@class LvimPreviewArtifactConfig
---@field prefix                string   reserved URL namespace for registered artifacts
---@field allow_client_messages boolean  master gate for INBOUND viewer messages (inverse search)
---@field watch_debounce        integer  ms, only for artifacts registered with `watch = true`
---@field stall_note_ms         integer  ms before the viewer notes a build is still running
---@field pdf                   LvimPreviewArtifactPdf  pdf.js viewer behaviour

---@class LvimPreviewConfig
---@field address    string          Bind address. Non-loopback (LAN) is an explicit act — health warns.
---@field port       integer         Preferred TCP port.
---@field auto_port  boolean         Scan upward from `port` when it is busy.
---@field browser    string|string[]|nil  nil = system opener; a command string or an argv list.
---@field auto_open  boolean         Open the browser on `:LvimPreview start`.
---@field root       string          "project" | "file" | an explicit absolute path.
---@field serve_hidden boolean       Serve dotfiles under the root (ON — a project's docs often live in
---                                   a dot-dir; the server is loopback-only, and `.env`/`.git` become
---                                   readable by anything on this machine, so set false to lock it down).
---@field debounce   integer         ms of idle before a type-driven push (md/org/svg).
---@field sync_scroll boolean        Editor→browser scroll sync (md/org).
---@field sync_scroll_back LvimPreviewSyncScrollBack  Browser→editor scroll sync (md/org), on by default.
---@field theme      "lvim"|"light"|"dark"|"auto"  Preview theme; "lvim" tracks the live palette.
---@field filetypes  string[]        Render kinds enabled for preview — the gate for the picker,
---                                   `preview_file` AND the HTTP router (see util.EXT_KIND).
---@field features   LvimPreviewFeatures  Client-side render toggles.
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
    -- nil → the platform opener (xdg-open / open / start). A string is split on spaces;
    -- an argv list ({ "firefox", "--new-window" }) is passed verbatim to vim.system (never
    -- a shell string), so paths with spaces are safe.
    browser = nil,
    auto_open = true,
    -- "project" — the project root (nearest ancestor with a root marker, else cwd); the whole
    --   tree is servable so relative links / images / css / js all resolve.
    -- "file" — the previewed file's own directory (re-rooted when the previewed file changes).
    -- "/abs/path" — an explicit servable root.
    root = "project",
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
        },
        org = {
            -- The one thing org readers really customise; everything else rides the flags above.
            todo_keywords = { "TODO", "DONE" },
        },
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
