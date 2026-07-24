# lvim-preview

A live browser preview for **Markdown**, **HTML**, **AsciiDoc** and **SVG**, served straight
from Neovim by an in-plugin pure-Lua (libuv) HTTP + WebSocket server. The page hot-reloads as
you type — Markdown / AsciiDoc / SVG update **without saving**, HTML refreshes on save — with
KaTeX math, Mermaid diagrams, syntax-highlighted code, and editor→browser sync scrolling.

Zero external runtimes: no Node, no Python. The server, the RFC 6455 WebSocket framing and the
file watching are all `vim.uv`. Every render asset is **vendored locally** — the served page
makes **no external / CDN request ever** and works fully offline. When `theme = "lvim"` the
preview CSS is generated from the live editor palette and re-pushed on `:colorscheme` changes,
so the browser tracks your theme.

## Features

- `:LvimPreview start [file]` — start the server and open the browser at the file's URL. Without
  an argument it previews the current buffer.
- **Hot reload as you type** for `markdown` / `asciidoc` / `svg` (debounced, no save, no temp
  files); **reload on save** for `html` (its own CSS / JS / images are served from the same
  root).
- **KaTeX** math, **Mermaid** diagrams, **highlight.js** code blocks — all client-side, all
  vendored.
- **Sync scrolling** (editor→browser) for Markdown and AsciiDoc.
- **`theme = "lvim"`** — preview colours generated from the lvim-utils palette, live-updated on
  `ColorScheme`; or fixed `"light"` / `"dark"` / `"auto"`.
- **Multi-client** — several browser tabs / devices stay in sync (pushes are broadcast).
- **lvim-ui picker** (`:LvimPreview pick`), an **lvim-hud serving chip** while running, and
  **lvim-msgarea** notifications.

## Safety

- **Loopback only by default** (`127.0.0.1`). Binding any other address exposes the preview
  **and every file under the root** to the LAN with **no authentication** — an explicit config
  act; `:checkhealth lvim-preview` warns when the bound address is non-loopback.
- **Path-traversal guarded** — every request is resolved on a segment stack that can never
  escape the root; no directory listings; dotfiles are hidden unless `serve_hidden = true`.
- **The browser never drives the editor** — inbound WebSocket traffic is limited to ping / pong
  / close; the page is a passive viewer.

## Requirements

- Neovim ≥ 0.10 (`vim.uv`, `vim.base64`, `vim.system`, `vim.fs.root`).
- A system browser opener (`xdg-open` / `open` / `start` / `wslview`) or a configured `browser`.
- Optional: **lvim-utils** (palette theme + merge), **lvim-ui** (the `pick` chooser),
  **lvim-hud** (the serving chip), **lvim-icons** (per-file icons in the chooser). All degrade
  gracefully when absent.

## Installation

Install with the lvim-tech **lvim-installer**, or with Neovim's native `vim.pack`:

```lua
vim.pack.add({
    { src = "https://github.com/lvim-tech/lvim-preview" },
})

require("lvim-preview").setup()
```

## Commands

| Command                   | Action                                                             |
| ------------------------- | ------------------------------------------------------------------ |
| `:LvimPreview start [file]` | Start the server, preview `file` (or the current buffer), open it. |
| `:LvimPreview stop`       | Stop the server and clear the serving chip.                        |
| `:LvimPreview open`       | Re-open the browser at the current preview URL.                    |
| `:LvimPreview status`     | Report address / port / root / previewed file / clients / theme.   |
| `:LvimPreview pick`       | Choose a previewable file under the root (lvim-ui select).         |

## Configuration

`setup()` merges your options into the live config in place. Every value at its default:

```lua
require("lvim-preview").setup({
    address = "127.0.0.1", -- bind address; non-loopback (LAN) is an explicit act — health warns
    port = 5500, -- preferred TCP port
    auto_port = true, -- scan upward from `port` when it is busy
    browser = nil, -- nil = system opener; a command string or an argv list ({ "firefox", "--new-window" })
    auto_open = true, -- open the browser on :LvimPreview start
    root = "project", -- "project" (root marker / cwd) | "file" (the file's dir) | "/explicit/path"
    serve_hidden = false, -- serve dotfiles under the root (off — .env / .git must not leak)
    debounce = 100, -- ms of idle before a type-driven push (md / adoc / svg)
    sync_scroll = true, -- editor→browser scroll sync (md / adoc)
    theme = "lvim", -- "lvim" (live palette) | "light" | "dark" | "auto"
    filetypes = { "markdown", "html", "asciidoc", "svg" }, -- previewable filetypes
    features = {
        katex = true, -- render $…$ / $$…$$ math with KaTeX
        mermaid = true, -- render ```mermaid fences as diagrams
        highlight = true, -- syntax-highlight fenced code (highlight.js)
        emoji = true, -- render :shortcode: emoji (markdown-it-emoji)
    },
    hud_chip = true, -- show the lvim-hud serving chip while the server runs
    notify = true, -- emit start / stop / port / client notifications
    icons = { -- Nerd Font single-width glyphs
        server = "", -- serving chip / status
        file = "󰈙", -- fallback document glyph (lvim-icons wins per file)
        pick = "", -- the picker title glyph
    },
})
```

## Root modes

- **`"project"`** — the nearest ancestor of the file with a root marker (`.git`, `.lvim`,
  `package.json`, `Cargo.toml`, `go.mod`, `Makefile`, …), else the cwd. The whole tree is
  servable, so relative links, images and page assets resolve.
- **`"file"`** — the previewed file's own directory (re-rooted when you preview another file).
- **an explicit path** — a fixed servable root.

The previewed file must live under the resolved root; otherwise `start` reports it (use
`root = "file"` or an enclosing path).

## Theme

`theme = "lvim"` (default) generates the preview CSS variables from the live lvim-utils palette
and re-pushes them on every `ColorScheme` / palette sync — the open page follows the editor with
no reload. `"light"` / `"dark"` use a fixed GitHub-ish palette; `"auto"` ships both and lets the
browser's `prefers-color-scheme` decide.

## Vendored assets

All render assets are pinned and served locally from `static/vendor/` (each with its upstream
LICENSE); see `static/vendor/README` for the version / license / source manifest.
`:checkhealth lvim-preview` verifies every asset is present — the offline guarantee. Nothing on
the page ever points at a CDN.

## Health

`:checkhealth lvim-preview` checks the Neovim / `bit` runtime, the optional ecosystem
integrations, the browser opener, config validity, the **security posture of the bind address**,
and the integrity of every vendored asset.

## License

BSD-3-Clause — see `LICENSE`. Vendored browser assets keep their own upstream licenses under
`static/vendor/`.
