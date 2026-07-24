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

---@class LvimPreviewFeatures
---@field katex     boolean  render `$…$` / `$$…$$` math with KaTeX
---@field mermaid   boolean  render ```mermaid fences as diagrams
---@field highlight boolean  syntax-highlight fenced code blocks (highlight.js)
---@field emoji     boolean  render `:shortcode:` emoji (markdown-it-emoji)

---@class LvimPreviewConfig
---@field address    string          Bind address. Non-loopback (LAN) is an explicit act — health warns.
---@field port       integer         Preferred TCP port.
---@field auto_port  boolean         Scan upward from `port` when it is busy.
---@field browser    string|string[]|nil  nil = system opener; a command string or an argv list.
---@field auto_open  boolean         Open the browser on `:LvimPreview start`.
---@field root       string          "project" | "file" | an explicit absolute path.
---@field serve_hidden boolean       Serve dotfiles under the root (off — `.env`/`.git` must not leak).
---@field debounce   integer         ms of idle before a type-driven push (md/adoc/svg).
---@field sync_scroll boolean        Editor→browser scroll sync (md/adoc).
---@field theme      "lvim"|"light"|"dark"|"auto"  Preview theme; "lvim" tracks the live palette.
---@field filetypes  string[]        Filetypes eligible for preview.
---@field features   LvimPreviewFeatures  Client-side render toggles.
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
    serve_hidden = false,
    debounce = 100,
    sync_scroll = true,
    theme = "lvim",
    filetypes = { "markdown", "html", "asciidoc", "svg" },
    features = {
        katex = true,
        mermaid = true,
        highlight = true,
        emoji = true,
    },
    hud_chip = true,
    notify = true,
    icons = {
        server = "", -- nf-fa-server
        file = "󰈙", -- nf-md-file_document
        pick = "", -- nf-fa-search
    },
}
