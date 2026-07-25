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
- **Static HTML export** (`:LvimPreview export [path]`) — write the current Markdown/org buffer to
  **one self-contained file that opens offline**: the rendered body, the theme, and only the render
  libraries the document actually uses are inlined (KaTeX's fonts embedded as `data:` URIs). A plain
  note stays tens of KB; a math + diagram document carries its libraries. No server, no network.
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
  act. `:checkhealth lvim-preview` warns when the bound address is non-loopback, and a non-loopback
  **start** is never silent: it emits a loud warning with the reachable URL(s) and pops a scannable
  QR so a phone opens the preview without typing an IP (both governed by the `lan` config).
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
| `:LvimPreview open [id]`  | Re-open the browser at the current preview URL, or at artifact `id`. |
| `:LvimPreview artifacts`  | List producer-registered artifacts; choose one to open (lvim-ui). |
| `:LvimPreview qr`         | Show a scannable QR of the preview URL — a phone on the LAN opens it. |
| `:LvimPreview status`     | Report address / port / root / previewed file / clients / theme.   |
| `:LvimPreview pick`       | Choose a previewable file under the root (lvim-ui select).         |
| `:LvimPreview export [path]` | Write the current buffer to a self-contained offline `.html` file. |

## Configuration

`setup()` merges your options into the live config in place. Every value at its default:

```lua
require("lvim-preview").setup({
    address = "127.0.0.1", -- bind address; non-loopback (LAN) is an explicit act — health warns
    port = 5500, -- preferred TCP port
    auto_port = true, -- scan upward from `port` when it is busy
    browser = nil, -- nil = system opener; a command string or an argv list ({ "firefox", "--new-window" })
    auto_open = true, -- open the browser on :LvimPreview start
    -- Set to your tunnel / forwarded public base URL (e.g. "https://preview.example.com" or
    -- "http://203.0.113.5:5500") to advertise THAT in the QR / status / start notice; nil derives from
    -- the bind. Never auto-discovered (that needs an external service) — you set what you exposed.
    public_url = nil, -- scheme://host[:port], or nil
    root = "project", -- "project" (root marker / cwd) | "file" (the file's dir) | "/explicit/path"
    -- "root" = serve any file under `root` (project cross-links work, but every file under root is
    -- readable by whatever reaches the port). "documents" = an allowlist: only the previewed files
    -- and the local sub-resources they reference (images…) are served; everything else 404s — the
    -- lockdown for a non-loopback / tunnelled bind, so exposure never means the whole tree.
    serve = "root", -- "root" | "documents"
    serve_hidden = true, -- serve dotfiles under the root (on — set false to keep .env / .git unreadable)
    -- Only fires when `address` is non-loopback (you deliberately expose the LAN). A loopback bind is
    -- silent. `warn` = a loud start-time WARN with the no-auth note + reachable URL(s); `qr` = also pop
    -- the scannable QR (`:LvimPreview qr` shows it on demand any time). Both on, so exposing is never silent.
    lan = {
        warn = true,
        qr = true,
    },
    -- Auto-tunnel: with enabled = true, start spawns `cmd` (a process that forwards this loopback
    -- server to a PUBLIC address and prints that URL), scrapes the URL with `url_pattern`, and puts it
    -- in the QR / status — no copy-paste of a dynamic address. Default = localhost.run over ssh (zero
    -- install, anonymous). Swap in another provider by changing cmd + url_pattern (serveo, cloudflared,
    -- …); `{port}` becomes the real bound port. The process is killed on stop / exit.
    tunnel = {
        enabled = false,
        cmd = { "ssh", "-o", "StrictHostKeyChecking=accept-new", "-R", "80:localhost:{port}", "localhost.run" },
        url_pattern = "https://[%w.%-]+%.lhr%.life",
    },
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
    -- Palette-derived detail for theme = "lvim" (the fixed light/dark/auto themes ignore it).
    -- Nothing here is a hardcoded colour: headings and code tokens are pulled LIVE from the
    -- tree-sitter highlight GROUPS the editor paints, base elements from named palette fields — so
    -- the preview is the editor's own colours and follows a colorscheme change with no reload. Each
    -- field is an OVERRIDE that pins a value; leave it nil to keep tracking the editor.
    theme_lvim = {
        -- Per-level heading text colour, h1..h6. nil (all six) → derive from the editor's markdown
        -- heading highlight (heading_groups[N], i.e. the palette rainbow), so the levels read as a
        -- hierarchy. Set an entry to a "#rrggbb" to pin that level.
        headings = { nil, nil, nil, nil, nil, nil },
        -- The tree-sitter group each level derives from when not pinned — exactly the groups the
        -- editor uses to colour markdown headings, so a preview heading equals the editor's.
        heading_groups = {
            "@markup.heading.1.markdown",
            "@markup.heading.2.markdown",
            "@markup.heading.3.markdown",
            "@markup.heading.4.markdown",
            "@markup.heading.5.markdown",
            "@markup.heading.6.markdown",
        },
        -- hljs code-token class → tree-sitter group. highlight.js tags code spans with `hljs-*`
        -- classes; each key maps a class to the editor capture whose colour it takes, pulled LIVE
        -- (so `hljs-keyword` is the same colour as `@keyword` in your buffer). highlight.js is
        -- coarser than tree-sitter, so several classes fold onto the nearest capture. WHICH hljs
        -- selectors each key drives, and its palette fallback, is the CODE_SPEC table in theme.lua.
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
            emoji = true, -- `:shortcode:` → its emoji glyph (full GitHub set; unknown = literal)
            footnotes = true, -- `[^ref]` + `[^ref]:` → a superscript link + an end list with a backlink
        },
        org = {
            todo_keywords = { "TODO", "DONE" }, -- keyword set the org parser treats as TODO states
        },
    },
    -- Static export: `:LvimPreview export [path]` writes the current buffer to ONE self-contained
    -- .html file that opens offline (rendered body + theme + inlined libraries with data: fonts).
    export = {
        dir = nil, -- nil = write beside the source file (basename.html); a dir path writes there
        embed = "auto", -- "auto" = inline ONLY the libraries the document uses (plain note stays small);
        -- "all" = force every feature-enabled library in (for a page that builds content after load)
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
            lazy = true, -- render a page only as it nears the viewport; release far canvases
            lookahead = 1, -- pages beyond the viewport (each side) kept painted ahead
            max_canvases = 8, -- most painted-page canvases retained at once
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
**typographic replacement** and **smart quotes**, **autolinking** of bare URLs, `:shortcode:`
**emoji** and **footnotes** (both on by default). GFM **task lists** are available but off by
default (`features.markdown.task_lists`), because switching them on changes `- [ ] todo` from
literal text into a rendered checkbox.

**Emoji** (`features.markdown.emoji`, on). A `:shortcode:` becomes its emoji glyph — the full
GitHub set (1913 shortcodes, generated from `github/gemoji` v4.1.0, MIT), so `:rocket:` → 🚀,
`:+1:` → 👍, `:tada:` → 🎉. The shortcode charset is GitHub's own (`:[\w+-]+:`). An **unknown name
is left verbatim** (`:not_an_emoji:` stays literal, never a broken glyph), a bare `:` or a `::` is
untouched, and a shortcode inside a code span or a fenced code block is never expanded. Turn the
feature off and every `:shortcode:` stays literal.

**Footnotes** (`features.markdown.footnotes`, on — so Markdown matches org, which has them). A
`text[^label]` reference becomes a superscript link, and the matching `[^label]: the note` block
collects into an ordered **Footnotes** list at the end of the document, each note carrying a
back-link (`↩`) to its reference. Labels are arbitrary (`[^1]`, `[^note]`). A reference to a label
with **no definition stays literal text** — never a dangling link. An **unreferenced definition is
dropped**, and a note referenced **more than once is numbered once with a back-link to each
reference** (`↩`, `↩2`, …) — both matching GitHub. References work inside list items and
blockquotes; a definition may span several paragraphs (continuation lines indented four spaces).

**Autolinking is stricter than it was**, on purpose. The previous renderer linkified *fuzzily* —
any word with a plausible TLD, no scheme required. Measured over this ecosystem's own
documentation that produced 9 wrong links and 2 right ones: `setup.py`, `noxfile.py`, `manage.py`
and `CLAUDE.md` all became `http://…` anchors. Autolinking here requires an explicit scheme, a
`www.` prefix or an email address.

**Not implemented:** fuzzy schemeless autolinks (as above), and Unicode special-case folding of
link reference labels (the one CommonMark example that differs functionally).

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
and fixed-width blocks; footnote definitions and references; **`#+CAPTION:`** (a table caption, or a `<figure>` caption on a lone image) and **`#+ATTR_HTML:`** (a safe allow-list — width / height / class / alt / title / id, so an image sizes and a table takes a class; scripting attributes are dropped); drawers (collapsible); timestamps;
horizontal rules; and LaTeX fragments (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) plus LaTeX environments
(`\begin{align}…\end{align}`), both handed to KaTeX.

**What does NOT render — deliberately, this is a reader, not an org exporter:** no Babel /
`#+BEGIN_SRC :results` execution, no `#+INCLUDE`, no macros (`{{{name}}}`), no `#+OPTIONS` export
switches, no agenda / clocking / column-view semantics.
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

## Static export

`:LvimPreview export [path]` writes the current Markdown or org buffer (unsaved edits included) to a
**single self-contained HTML file** that opens straight from the filesystem — no server, no network,
no external request. It is a **snapshot**: the rendered document at that moment, with no live update
and no scroll sync. Everything the page needs is inlined — the rendered body, the base + theme CSS,
and any render libraries the document uses, with the fonts those stylesheets reference embedded as
`data:` URIs (so KaTeX still typesets and Mermaid still draws from a `file://` URL).

**Conditional inlining is the point.** Mermaid is ~2.5 MB and KaTeX ~640 KB, so `embed = "auto"` (the
default) inlines a library **only when the document actually uses it** — KaTeX only with math,
Mermaid only with a `mermaid` fence, highlight.js only with a fenced code block. A plain note exports
in tens of KB; a math + diagram document carries its libraries (a few MB). The decision reuses the
same asset selection the live page uses, so the export and the served page never disagree about what
a document needs. Set `embed = "all"` to force every enabled library in — for a page that builds its
diagrams or math dynamically after load.

- **Output path** — omitted, it is the buffer's basename with `.html`, written beside the source
  file (or under `export.dir` when set). A path argument may be a file or a directory. An existing
  target is never overwritten silently — a themed lvim-ui prompt confirms first.
- On success the written path and the file size are reported (a 4 MB export vs a 40 KB one is worth
  seeing).
- The **current theme** is snapshotted into the file, so an export opened weeks later does not depend
  on the editor being open.

```vim
:LvimPreview export                      " → <buffer>.html beside the file
:LvimPreview export ~/public/notes.html  " → an explicit path
:LvimPreview export ~/public/            " → ~/public/<buffer>.html
```

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
- **Lazy rendering** (`artifact.pdf.lazy`, on by default): a page is rasterised only as it nears
  the viewport (an `IntersectionObserver` over correctly-sized per-page placeholders), and a page
  scrolled far away has its canvas released and re-rendered on return — so an arbitrarily long PDF
  (a 500-page thesis) never holds hundreds of canvases. `lookahead` paints the page just past the
  fold ahead of time for smooth scrolling; `max_canvases` caps how many are retained (the nearest
  to the viewport win). Because every page keeps a stable-height placeholder either way, position
  restore across a rebuild and forward-search to a not-yet-painted page both work — a `synctex`
  jump paints its target page on arrival. Set `lazy = false` to rasterise every page up front.
- **CJK text and JPEG-2000 images** render fully offline: the CJK character maps (`cmaps/`) and the
  WebAssembly image decoders (`wasm/` — JPEG-2000 / JBIG2 and the ICC colour transform) are
  vendored beside pdf.js and served locally, loaded strictly **on demand**. A plain-Latin PDF pulls
  none of them, so the common case downloads nothing extra; a document that needs a CJK glyph or a
  JPEG-2000 image fetches only the specific map / decoder it requires.
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

`theme = "lvim"` (default) makes the preview an extension of the editor, not a foreign document:
it is generated from the LIVE editor and re-pushed whenever the palette changes, so the open page
follows the editor with **no reload and no re-run of `:LvimPreview`**. `"light"` / `"dark"` use a
fixed GitHub-ish palette; `"auto"` ships both and lets the browser's `prefers-color-scheme` decide.

Under `theme = "lvim"`:

- **Base document** — background, body text, links, blockquotes, inline code, tables and the text
  selection are painted from named lvim-utils palette fields (see `theme_lvim.*` above; every one is
  overridable).
- **Headings h1–h6** — each level takes the colour the editor gives that markdown heading level
  (`@markup.heading.N.markdown`, the palette rainbow), so the six levels read as a hierarchy that
  matches your buffer. Pin any level with `theme_lvim.headings[N]`.
- **Fenced code** — highlight.js tags code spans with `hljs-*` classes; the "lvim" theme paints
  each class with the SAME colour the editor gives the corresponding tree-sitter capture, pulled
  live with `nvim_get_hl`. So a `local` keyword in a preview code block is the exact colour of
  `@keyword` in your editor. (The fixed light/dark themes keep the vendored GitHub hljs stylesheet
  instead — they have no live palette to derive from.)

highlight.js is coarser than tree-sitter (no field-vs-variable distinction, class names read as
types, and so on), so several `hljs-*` classes fold onto the nearest capture. The mapping is
inspectable and overridable — `theme_lvim.code` (hljs class → group) above, and the full
selector/fallback table (`CODE_SPEC`) in `lua/lvim-preview/theme.lua`:

| hljs class(es) | tree-sitter group | meaning |
|---|---|---|
| `hljs-keyword` `hljs-doctag` `hljs-template-tag/-variable` | `@keyword` | keywords |
| `hljs-title` `hljs-title.function_` `hljs-function` | `@function` | function names |
| `hljs-built_in` | `@function.builtin` | built-in functions |
| `hljs-type` `hljs-title.class_` | `@type` | types / class names |
| `hljs-variable` | `@variable` | variables |
| `hljs-variable.language_` | `@variable.builtin` | `this` / `self` |
| `hljs-attr` `hljs-attribute` `hljs-property` | `@property` | fields / attributes |
| `hljs-string` `hljs-meta .hljs-string` `hljs-code` | `@string` | strings |
| `hljs-regexp` | `@string.regexp` | regexes |
| `hljs-number` | `@number` | numbers |
| `hljs-literal` | `@constant.builtin` | `true` / `false` / `null` |
| `hljs-symbol` | `@constant` | symbols / atoms |
| `hljs-comment` `hljs-quote` `hljs-formula` | `@comment` | comments |
| `hljs-operator` | `@operator` | operators |
| `hljs-punctuation` | `@punctuation.delimiter` | punctuation |
| `hljs-meta` | `@keyword.directive` | preprocessor / decorators |
| `hljs-name` `hljs-selector-tag/-pseudo` `hljs-tag` | `@tag` | tag names |
| `hljs-selector-attr/-class/-id` | `@variable` | CSS selectors |
| `hljs-section` | `@markup.heading` | section titles |
| `hljs-bullet` | `@markup.list` | list bullets |
| `hljs-addition` / `hljs-deletion` | `@diff.plus` / `@diff.minus` | diff hunks |

**Live updates.** The preview follows the palette on both change paths: a plain `:colorscheme`
(native `ColorScheme`) and the way lvim-colorscheme actually applies its themes — the picker's
live-preview variant switches, which fire `User LvimColorscheme` and never go through native
`ColorScheme`. Both re-push the generated CSS to every open tab, so changing the theme in the
editor recolours the browser's document, headings and code at once, without a reload.

The static export (`:LvimPreview export`) snapshots the generated CSS into the file, so an exported
document carries these exact palette code colours and opens correctly offline.

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
