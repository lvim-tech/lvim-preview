# lvim-preview

A live browser preview for **Markdown** and **org**, served
straight from Neovim by an in-plugin pure-Lua (libuv) HTTP + WebSocket server. The page hot-reloads
as you type — both update **without saving** —
with KaTeX math, Mermaid diagrams, syntax-highlighted code, and sync scrolling that can run
**both ways**.

It is also the **display half** for plugins that BUILD something: a producer registers the file it
compiles (a PDF, a generated page) and lvim-preview serves it, live-reloads it on the producer's
signal, and scrolls it on a forward-search request — see [Build artifacts](#build-artifacts).

Zero external runtimes: no Node, no Python. The server, the RFC 6455 WebSocket framing, the file
watching and **both the Markdown and the org parser** are in-plugin (`vim.uv` and plain Lua). Every
render asset is
**vendored locally** — the served page makes **no external / CDN request ever** and works fully
offline. When `theme = "lvim"` the
preview CSS is generated from the live editor palette and re-pushed on `:colorscheme` changes,
so the browser tracks your theme.

## Features

- `:LvimPreview start [file]` — start the server and open the browser at the file's URL. Without
  an argument it previews the current buffer.
- **Hot reload as you type** for `markdown` and `org` (debounced, no save, no temp files). The
  frame carries finished HTML, so the page replaces its content in place and never reloads.
- **KaTeX** math (with your own macros and optional `mhchem` chemistry), **Mermaid** diagrams,
  **highlight.js** code blocks — all client-side, all vendored.
- **Sync scrolling both ways** — editor→browser always, browser→editor when you opt in. Every
  block carries the source line it came from, so neither direction guesses.
- **Markdown and org are rendered in Lua, inside Neovim** — no JavaScript parser on the page. The
  Markdown renderer matches 644 of the 652 CommonMark 0.31.2 conformance examples byte-for-byte
  (7 of the other 8 render identically in a browser), plus GFM tables and strikethrough.
- **Build artifacts** — a public `register_artifact` API for plugins that compile something;
  a vendored pdf.js viewer that keeps your page and scroll position across every rebuild.
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
  escape the root; no directory listings; dotfiles are served (set `serve_hidden = false` to hide them).
- **The browser never drives the editor unless you say so** — inbound WebSocket traffic is
  limited to ping / pong / close, and the page is a passive viewer. There are exactly two opt-in
  relaxations, each with its own flag, off by default, and each accepting only its own message:
  - **inverse search** on a build artifact — needs `artifact.allow_client_messages = true` **and**
    an `on_message` handler in that artifact's own registration;
  - **browser→editor sync scroll** — needs `sync_scroll_back.enabled = true`; only the
    `scroll_source` message is accepted, only for a previewed Markdown/org document, and only
    into a window that is already visible. Nothing is opened, no buffer is switched and the
    current window never changes.

  Anything else from a page — a different message type, a message for a document that is not
  previewed, any binary frame — is discarded exactly as it was before either flag existed.

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
    serve_hidden = true, -- serve dotfiles under the root (on — set false to keep .env / .git unreadable)
    debounce = 100, -- ms of idle before a type-driven push (md / org)
    sync_scroll = true, -- editor→browser scroll sync (md / org)
    -- Browser→editor scroll sync (the way back). On by default: a page scroll moves the editor window.
    sync_scroll_back = {
        enabled = true, -- master gate
        move = "view", -- "view" (scroll the window, keep the cursor) | "cursor"
        place = "top", -- "top" (same reference point both ways) | "center" (zz-like)
        throttle = 80, -- ms between two scroll reports from the page
        settle = 300, -- ms the side that moved last owns the sync
    },
    theme = "lvim", -- "lvim" (live palette) | "light" | "dark" | "auto"
    -- The render KINDS enabled. Removing one makes every file mapping to it non-previewable
    -- everywhere at once: the picker stops offering it, `start` refuses it, the server stops
    -- wrapping it. (Extension → kind lives in util.EXT_KIND.)
    filetypes = { "markdown", "org" },
    features = {
        katex = true, -- render $…$ / $$…$$ math with KaTeX
        katex_macros = {}, -- name → expansion, e.g. { ["\\RR"] = "\\mathbb{R}" }
        katex_mhchem = false, -- load the vendored mhchem contrib (\ce{H2O} chemistry)
        mermaid = true, -- render ```mermaid fences as diagrams
        highlight = true, -- syntax-highlight fenced code (highlight.js)
        markdown = {
            -- The two passes that are NOT CommonMark. Both on by default; turn them off to see
            -- exactly what you typed.
            typographer = true, -- (c) → ©, -- → –, ... → …, straight quotes → curly
            linkify = true, -- bare https://…, www.… and email addresses become links
            task_lists = false, -- render `- [ ]` / `- [x]` as a disabled checkbox item
        },
        org = {
            todo_keywords = { "TODO", "DONE" }, -- keyword set the org parser treats as TODO states
        },
    },
    -- Build artifacts: files another plugin PRODUCES, served and reloaded on its signal.
    -- Nothing here is used until a producer calls register_artifact().
    artifact = {
        prefix = "/@lvim-artifact/", -- reserved URL namespace
        allow_client_messages = false, -- master gate for inbound viewer→editor messages
        watch_debounce = 100, -- ms, only for artifacts registered with watch = true
        stall_note_ms = 10000, -- ms before the viewer notes a build is still running
        pdf = {
            restore_position = true, -- keep page / scroll across a producer reload
            highlight_ms = 1200, -- ms a forward-search highlight rect stays visible
        },
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

## Sync scrolling

Every block the Markdown and org renderers emit carries the source line it came from
(`data-source-line`), so both directions address a line, not a percentage.

**Editor → browser** (`sync_scroll`, on by default). Scrolling or moving in a previewed buffer
sends its top window line; the page jumps to the block that line belongs to.

**Browser → editor** (`sync_scroll_back.enabled`, **off** by default). Scrolling the page reports
the source line at the top of the viewport and the editor follows:

- **The view moves, not the cursor** (`move = "view"`). Scrolling is reading, not editing, so your
  cursor stays where you left it. It is only dragged along when the new view no longer contains it
  — exactly what `CTRL-E` / `CTRL-Y` do, because a window's cursor cannot be off screen. Set
  `move = "cursor"` to put the cursor on the reported line instead.
- **Nothing is stolen.** Only a window that is already showing that document, in the current
  tabpage, is scrolled. No `:edit`, no buffer switch, no change of the current window. If the
  document is not visible — you are working on something else — the message is discarded and
  nothing at all happens.
- **It cannot ping-pong.** The side that moved last owns the sync for `settle` ms and movement
  reported by the other side is ignored for that long, so the echo of the editor's own scroll can
  never come back as a new command; and neither side ever sends a line equal to the last one
  exchanged, so the steady state produces no message at all. With the default `place = "top"` the
  two directions share one reference point (the top of the viewport ↔ the top window line) and a
  round trip is an exact fixed point. Measured: a single wheel step produces exactly one message
  and then silence; 22 interleaved scrolls on both sides over five seconds produced 11 messages
  and none at all in the three seconds after the last one.
- Turning it on also makes the **editor→browser** jump instant and top-aligned instead of a
  centred smooth glide. That is not a preference: a smooth animation keeps firing scroll events
  long after the frame that caused it, and those are indistinguishable from your own scrolling.

**The known limit: precision is block-level.** The anchors are blocks, so the exact line is only
known at a block boundary. Inside a block the reported line is interpolated from how far the block
has scrolled past the top of the viewport, which assumes its source lines are spread evenly over
its rendered height — true for wrapped prose and code, approximate for a block whose height comes
from something other than its text (an image, a diagram, a math display). The interpolation is
clamped to the block, so the worst case is exactly the block's own first line. In practice
scrolling to the middle of a long paragraph puts you on that paragraph, not on its exact line.

```lua
require("lvim-preview").setup({
    sync_scroll_back = { enabled = true },
})
```

## Markdown

`.md` files are parsed and rendered to HTML by **our own Lua**, running in Neovim — there is no
vendored Markdown library and the page loads no Markdown JavaScript at all. The same
`server_render` seam serves the first paint and every live update, so they can never disagree.

**Conformance.** 644 of the 652 **CommonMark 0.31.2** conformance examples match byte-for-byte
(98.8%). Of the remaining 8, seven render identically in a real browser — six differ only in
whether a named character reference is written out (`&ouml;`) or decoded (`ö`), which the browser
resolves either way, and the URLs they produce resolve to the same absolute URL. The one genuine
gap is Unicode *special-case* folding in a link reference label (`[ẞ]` matching `[SS]:`); simple
case folding, including Latin-1, Greek and Cyrillic, does work.

**Extensions**, matching what the previous browser renderer had enabled: GFM pipe **tables** (with
alignment and `\|` escapes), **strikethrough** (`~~text~~` → `<s>`), raw **HTML** pass-through,
**typographic replacement** and **smart quotes**, and **autolinking** of bare URLs. GFM **task
lists** are available but off by default (`features.markdown.task_lists`), because switching them
on changes `- [ ] todo` from literal text into a rendered checkbox.

**Autolinking is stricter than it was**, on purpose. The previous renderer linkified *fuzzily* —
any word with a plausible TLD, no scheme required. Measured over this ecosystem's own
documentation that produced 9 wrong links and 2 right ones: `setup.py`, `noxfile.py`, `manage.py`
and `CLAUDE.md` all became `http://…` anchors. Autolinking here requires an explicit scheme, a
`www.` prefix or an email address.

**Not implemented:** `:shortcode:` **emoji** (it needed the vendored Markdown plugin that went
away with the renderer), and fuzzy schemeless autolinks as above.

**Malformed input is preserved, never dropped.** An unclosed fence runs to the end of its
container with its body intact, a half-typed table keeps its cells, a reference definition that
does not parse stays paragraph text, and an unbalanced `*` stays the literal character.

The parser is a self-contained module (`lua/lvim-preview/markdown/`) with a documented public API
over a document tree — see `:help lvim-preview-markdown-api`. Like the org parser it is written to
be shared with other lvim-tech plugins later, so nothing HTML-specific lives in the parsing core.

## org-mode

`.org` files are parsed and rendered to HTML by **our own Lua**, running in Neovim — there is no
vendored org library and the page loads no org JavaScript at all. The result goes into the same
prose page Markdown uses, so it gets the same theme, the same highlight.js code blocks, the same
KaTeX pass and the same `data-source-line` sync scrolling. Live updates as you type send the
rendered HTML over the same WebSocket, with no page reload.

**What renders:** headings with TODO keywords (`features.org.todo_keywords`, including a `|`
separator for DONE states), priority cookies (`[#A]`), tags, and per-headline `:PROPERTIES:`;
`#+TITLE:` / `#+SUBTITLE:` / `#+AUTHOR:` / `#+DATE:` as a page header; plain, ordered and
description lists, nested to any depth, with continuation paragraphs and **checkboxes**
(`- [ ]`, `- [X]`, `- [-]`); tables with header separation (ragged rows are padded, never
dropped); links, images and targets — `[[file:./img.png]]` resolves against the served root;
inline markup (`*bold*`, `/italic/`, `_underline_`, `+strike+`, `=verbatim=`, `~code~`), braced
`^{sup}` / `_{sub}`, and hard `\\` line breaks; `#+BEGIN_SRC` (highlighted by language, and
`#+BEGIN_SRC mermaid` becomes a diagram), `QUOTE`, `EXAMPLE`, `VERSE`, `CENTER`, `EXPORT html`
and fixed-width blocks; footnote definitions and references; drawers (collapsible); timestamps;
horizontal rules; and LaTeX fragments (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) plus LaTeX environments
(`\begin{align}…\end{align}`), both handed to KaTeX.

**What does NOT render — deliberately, this is a reader, not an org exporter:** no Babel /
`#+BEGIN_SRC :results` execution, no `#+INCLUDE`, no macros (`{{{name}}}`), no `#+OPTIONS` export
switches, no agenda / clocking / column-view semantics, and no `#+CAPTION:` / `#+ATTR_HTML:`
attachment (those keywords are parsed and kept in the tree, but nothing is rendered from them).
Org's *unbraced* `a_b` sub/superscripts are not applied — only `a_{b}` — because there is no way
to tell a subscript from a `snake_case` word in prose. An absolute `[[file:/abs/path]]` link will
not resolve (only paths under the servable root can). `#+BEGIN_EXPORT latex` is shown as text
rather than injected.

**Malformed input is preserved, never dropped.** An unclosed `#+BEGIN_SRC` or drawer ends at its
section boundary with its body intact, an unbalanced emphasis marker stays literal text, an
unrecognised `#+` line is kept, and a table you are half-way through typing keeps rendering.

The parser is a self-contained module (`lua/lvim-preview/org/`) with a documented public API over
a document tree — see `:help lvim-preview-org-api`. It is written to be shared with other
lvim-tech plugins later, so nothing HTML-specific lives in the parsing core.

## Build artifacts

A plugin that COMPILES something registers the file it produces; lvim-preview serves it and
refreshes the viewer when the producer says the build finished. The producer owns the toolchain
and the build lifecycle — lvim-preview compiles nothing and knows nothing about the format.

```lua
local handle = require("lvim-preview").register_artifact({
    id = "tex:" .. main_tex, -- stable, free-form; re-registering keeps the same URL
    path = "/abs/path/build/main.pdf", -- need not exist yet
    viewer = "pdf", -- optional: inferred from the extension (pdf | html | raw)
    title = "main.pdf", -- optional: defaults to the basename
    watch = false, -- optional: true = a uv fs watcher reloads on write
    on_message = nil, -- optional: inbound viewer messages (inverse search)
})

handle:url() --> "http://127.0.0.1:5500/@lvim-artifact/a1/"
handle:status("building") --  spinner over the LAST GOOD render; nothing refetches
handle:status("error", first_line) --  red strip; the old render stays visible
handle:reload() --  the file is new and coherent → the viewer refetches
handle:synctex({ page = 3, x = 100, y = 250 }) --  scroll there and flash a rect
handle:close() --  unregister; the last document/artifact closed stops the server
```

- Artifacts are served under the reserved `artifact.prefix`, with the produced file's **own
  directory** as the confined serve root — build output does not have to live under the project
  root that documents are served from, and the same traversal guard applies.
- `register_artifact` starts the server if it is not running. An artifact keeps it alive on its
  own, so closing the last previewed document does not pull the page out from under a build.
- **`reload()` is the default, not a file watcher, on purpose:** only the producer knows a build
  finished coherently. A half-written PDF must never be fetched, and tools differ (some write in
  place, some write-then-rename). `watch = true` is available for producers with no completion
  signal; it watches the file's directory, so a write-then-rename still fires.
- `viewer = "pdf"` renders through a vendored **pdf.js** and **restores your page and scroll
  offset after every rebuild** (`artifact.pdf.restore_position`) — the browser's built-in PDF
  viewer resets to page 1 and offers no hook for forward search. `+` / `-` / `0` zoom.
- `viewer = "html"` serves the produced page with the reload client injected. `viewer = "raw"`
  serves the bytes with their MIME type and no wrapper — addressable and re-fetchable, but with
  no client on the page nothing listens for reload frames.
- **`synctex` coordinates:** `page` is 1-based; `x` / `y` / `width` / `height` are PDF points from
  the **top-left of that page** — exactly what `synctex view` reports. The producer resolves the
  target; lvim-preview only displays it.
- **Inverse search** (ctrl-click in the viewer → your editor) requires BOTH
  `artifact.allow_client_messages = true` and an `on_message` handler on that artifact. The
  handler receives `{ type = "synctex_edit", path, page, x, y }` on the main thread.

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

Every vendored asset is permissively licensed (MIT / BSD-3-Clause / Apache-2.0), matching this
plugin's own BSD-3-Clause. **There is no vendored Markdown or org renderer**: both formats are
parsed and rendered by our own Lua (`lua/lvim-preview/markdown/`, `lua/lvim-preview/org/`) and the
page loads no parser library at all — every document kind this plugin serves is rendered in Lua
before it reaches the browser. What remains vendored is not a parser but a LAYOUT engine: KaTeX
typesets math and Mermaid lays out diagrams, and neither is a job a parser can do — plus a code
highlighter, pdf.js for the artifact viewer, and one stylesheet.

## Health

`:checkhealth lvim-preview` checks the Neovim / `bit` runtime, the optional ecosystem
integrations, the browser opener, config validity, the **security posture of the bind address**,
and the integrity of every vendored asset.

## License

BSD-3-Clause — see `LICENSE`. Vendored browser assets keep their own upstream licenses under
`static/vendor/`.
