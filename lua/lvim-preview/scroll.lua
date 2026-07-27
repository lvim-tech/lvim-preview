-- lvim-preview.scroll: sync scroll BOTH ways for the two anchored kinds (markdown, org).
--
-- OUT (editor→browser, config.sync_scroll): a WinScrolled / CursorMoved on a previewed buffer
-- broadcasts a `scroll` frame carrying the top visible line and the buffer's line count; the client
-- jumps to the block with the matching `data-source-line` (markdown and org both stamp them), or
-- falls back to a proportional scroll.
--
-- IN (browser→editor, config.sync_scroll_back.enabled, on by default): the page reports the
-- source line at the top of its viewport as a `scroll_source` message and this module moves the
-- window that shows that document. It is the second — and equally narrow — relaxation of the
-- "browser is a passive viewer" rule (the first is artifact inverse search): its own config flag,
-- its own gate in the read loop, and exactly ONE accepted message shape. Three rules bound it:
--   * MOVE THE VIEW, NOT THE CURSOR (config `move`). Scrolling is reading, not editing.
--   * NEVER STEAL FOCUS. Only a window ALREADY showing that buffer in the CURRENT tabpage is
--     scrolled; nothing is opened, no buffer is switched, the current window never changes. When
--     the document is not visible the message is discarded — the user is looking at something else.
--   * NEVER OSCILLATE. See "the settle window" below.
--
-- THE SETTLE WINDOW (why two-way scroll does not ping-pong). Two independent mechanisms, so the
-- loop is broken by construction rather than damped:
--   1. OWNERSHIP. Whoever moved the other side last OWNS the sync for `settle` ms; movement
--      reported by the other side inside that window is dropped (and dropping it does not extend
--      the window, so control always changes hands after one quiet interval). This is what stops
--      the echo of our own `winrestview` — the WinScrolled it raises finds the browser owning.
--   2. VALUE EQUALITY. Applying an inbound line records it as this document's last exchanged line,
--      and neither side ever sends a line equal to the last one exchanged. With the default
--      `place = "top"` a round trip is an exact fixed point (the page reports the source line at
--      its viewport top, the editor puts that line at `w0` and reports `w0`), so after the window
--      expires the steady state produces no message at all — there is nothing left to oscillate.
-- `settle = 300` ms: it must exceed the longest tail of in-flight movement from the losing side —
-- one client throttle interval (80 ms) plus a loopback round trip (well under 10 ms) — with room
-- for a queued burst, and it must stay short enough that handing control over feels immediate
-- (scroll the page, then immediately scroll the editor: 300 ms is under the ~500 ms at which a
-- deliberate hand-over starts to feel stuck).
--
-- PER DOCUMENT: every previewed file owns its augroup, its last-line marker and its ownership
-- record, so several documents scroll-sync at once and each frame is addressed by that document's
-- `url_path`.
--
---@module "lvim-preview.scroll"

local api = vim.api
local uv = vim.uv
local config = require("lvim-preview.config")
local state = require("lvim-preview.state")
local server = require("lvim-preview.server")

local M = {}

---@type table<string, string>  doc path → its augroup name
local groups = {}
---@type table<string, integer>  doc path → last line exchanged either way, to suppress echoes
local last_line = {}
---@type table<string, { side: "editor"|"browser", deadline: integer }>  doc path → sync ownership
local owner = {}
---@type integer  augroup-name counter (a path is not a legal group name)
local seq = 0

-- Kinds whose rendered page can be scrolled to a source line (anchors or a proportional
-- fallback), and whose page can therefore report one back.
---@type table<string, boolean>
local SYNCABLE = { markdown = true, org = true }

--- Take the sync for `side`, for `config.sync_scroll_back.settle` ms.
---@param doc LvimPreviewDoc
---@param side "editor"|"browser"
---@return nil
local function claim(doc, side)
    local settle = math.max(0, (config.sync_scroll_back or {}).settle or 300)
    owner[doc.file] = { side = side, deadline = uv.now() + settle }
end

--- Is `side` currently locked out — i.e. did the OTHER side move this document less than
--- `settle` ms ago? Read-only: a losing message must not extend the winner's window.
---@param doc LvimPreviewDoc
---@param side "editor"|"browser"
---@return boolean
local function locked_out(doc, side)
    local o = owner[doc.file]
    return o ~= nil and o.side ~= side and uv.now() < o.deadline
end

-- ── out: editor → browser ────────────────────────────────────────────────

--- Broadcast the current window's top line for `doc`, when its buffer is the focused one.
---@param doc LvimPreviewDoc
local function send_scroll(doc)
    local buf = doc.bufnr
    if not buf or api.nvim_get_current_buf() ~= buf then
        return
    end
    -- The browser moved us moments ago: this WinScrolled is the echo of our own winrestview.
    if locked_out(doc, "editor") then
        return
    end
    -- The top visible line drives the browser scroll (what the reader is looking at).
    local top = vim.fn.line("w0")
    if top == last_line[doc.file] then
        return
    end
    last_line[doc.file] = top
    claim(doc, "editor")
    server.broadcast({
        type = "scroll",
        path = doc.url_path,
        line = top,
        total = api.nvim_buf_line_count(buf),
    })
end

-- ── in: browser → editor ─────────────────────────────────────────────────

--- Every window in the CURRENT tabpage showing `buf`. A document that is not visible right now is
--- not scrolled at all — the browser may move a view the user can see, never open or switch one.
--- All matching windows move: they show the same document, and picking one of them would be
--- arbitrary.
---@param buf integer
---@return integer[]
local function visible_windows(buf)
    local wins = {}
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
            wins[#wins + 1] = win
        end
    end
    return wins
end

--- Effective 'scrolloff' for `win` (the option is global-local; -1 means "use the global value").
---@param win integer
---@return integer
local function scrolloff_of(win)
    local so = api.nvim_get_option_value("scrolloff", { win = win })
    if type(so) ~= "number" or so < 0 then
        so = vim.o.scrolloff
    end
    return so
end

--- Move ONE window so that `line` sits where `place` says, without focusing it.
---
--- `nvim_win_call` runs `winrestview` in that window's context — no `:edit`, no window switch, no
--- change of the current window. In "view" mode the cursor is kept and only clamped back into the
--- visible range when the new view no longer contains it, which is exactly what CTRL-E / CTRL-Y do
--- (a window's cursor cannot be off screen, so "the cursor never moves" is only meaningful while
--- the scroll region still holds it).
---@param win integer
---@param buf integer
---@param line integer  1-based target line
---@param opts { place: ("top"|"center")?, move: ("view"|"cursor")? }?  overrides `sync_scroll_back`
---   for a caller that owns its own policy (see `M.place_source`)
---@return nil
local function place_view(win, buf, line, opts)
    local back = config.sync_scroll_back or {}
    if opts then
        back = vim.tbl_extend("force", back, opts)
    end
    local count = api.nvim_buf_line_count(buf)
    local height = api.nvim_win_get_height(win)
    line = math.max(1, math.min(line, count))
    api.nvim_win_call(win, function()
        local view = vim.fn.winsaveview()
        local top = line
        if back.place == "center" then
            -- CENTRED BY ROW, not by line arithmetic. `line - height/2` assumes one screen row per
            -- buffer line, which 'wrap' breaks: measured on wrapped prose, that formula leaves the
            -- requested line 1–9 lines away from the middle row. Two things went wrong with it — the
            -- view was simply not centred on what it claimed, and the caller's echo suppression
            -- compares the placed line with the line at the middle row, so they never matched and
            -- the editor answered its own placement. `zz` is what centres a line by row; only its
            -- resulting topline is taken, and the cursor is put back below.
            api.nvim_win_set_cursor(win, { line, 0 })
            vim.cmd("keepjumps normal! zz")
            top = vim.fn.line("w0")
        end
        top = math.max(1, math.min(top, count))
        view.topline = top
        if back.move == "cursor" then
            view.lnum = line
            view.col = 0
            view.curswant = 0
        else
            local so = math.min(scrolloff_of(win), math.floor(math.max(0, height - 1) / 2))
            local lo = math.min(top + so, count)
            local hi = math.max(1, math.min(top + height - 1 - so, count))
            view.lnum = math.max(lo, math.min(view.lnum, hi))
        end
        vim.fn.winrestview(view)
    end)
end

--- Apply one reported source line to the document served at `url_path`. Main thread.
--- `source` is the client that reported it: the editor follows, and the SAME line is fanned out to
--- every OTHER viewer of this document (never back to `source`, which is already there), so two tabs
--- on one file stay in lockstep. The fan-out cannot ping-pong: a client that receives a `scroll`
--- frame goes quiet (`back.quietUntil`) and never echoes it, and the editor's own WinScrolled echo is
--- locked out by the ownership claim below.
---@param url_path string
---@param line integer
---@param source LvimPreviewClientCtx?  the client that reported this scroll
---@return nil
local function apply_scroll(url_path, line, source)
    local back = config.sync_scroll_back or {}
    -- Re-checked here, not only at the gate: the config is live and may have been turned off
    -- between the read loop and this scheduled call.
    if not back.enabled then
        return
    end
    local doc = state.doc_for_url(url_path)
    if not doc or not SYNCABLE[doc.filetype] then
        return
    end
    -- The editor moved the page moments ago; it keeps the sync until its window expires.
    if locked_out(doc, "browser") then
        return
    end
    local buf = doc.bufnr
    if not buf or not api.nvim_buf_is_valid(buf) then
        return
    end
    local wins = visible_windows(buf)
    if #wins == 0 then
        return
    end
    line = math.max(1, math.min(line, api.nvim_buf_line_count(buf)))
    if line == last_line[doc.file] then
        return
    end
    -- Claim BEFORE moving: winrestview raises WinScrolled, and that echo must find us owning.
    claim(doc, "browser")
    last_line[doc.file] = line
    for _, win in ipairs(wins) do
        place_view(win, buf, line)
    end
    -- Mirror the move to every OTHER viewer (the editor's own WinScrolled echo is suppressed by the
    -- claim, so this explicit fan-out is what keeps a second tab in sync).
    server.broadcast({
        type = "scroll",
        path = doc.url_path,
        line = line,
        total = api.nvim_buf_line_count(buf),
    }, source)
end

--- Deliver one inbound viewer message to the scroll path.
---
--- Called from the WebSocket read loop (a libuv fast context) ONLY when
--- `config.sync_scroll_back.enabled` is on. Exactly ONE message shape is accepted —
--- `{ type = "scroll_source", path = <document url_path>, line = <1-based source line> }` — and a
--- message that is anything else, or that names no previewed document, is discarded without a
--- trace, exactly as every client frame was before this direction existed.
---@param payload string  the raw text-frame payload
---@param source LvimPreviewClientCtx?  the client that sent it (fanned out to the others, not to it)
---@return nil
function M.dispatch_client_message(payload, source)
    local ok, msg = pcall(vim.json.decode, payload)
    if not ok or type(msg) ~= "table" then
        return
    end
    if msg.type ~= "scroll_source" or type(msg.path) ~= "string" or type(msg.line) ~= "number" then
        return
    end
    local line = math.floor(msg.line)
    local url_path = msg.path
    vim.schedule(function()
        apply_scroll(url_path, line, source)
    end)
end

-- ── lifecycle ────────────────────────────────────────────────────────────

--- Install the sync-scroll autocmds for one document. No-op when sync_scroll is off or the kind
--- carries no source-line mapping. Idempotent per document. The INBOUND direction needs no
--- autocmd — it is driven by the read loop — so it works whether or not this attached.
---@param doc LvimPreviewDoc
---@return nil
function M.attach(doc)
    M.detach(doc)
    if not config.sync_scroll or not SYNCABLE[doc.filetype] then
        return
    end
    seq = seq + 1
    local name = "LvimPreviewScroll_" .. seq
    groups[doc.file] = name
    local grp = api.nvim_create_augroup(name, { clear = true })
    -- By FILE, not a fixed bufnr — the same reason watch.attach does: lvim-space / `:edit` / a
    -- session restore recreate the buffer under a NEW number, and a buffer-scoped autocmd would be
    -- left on the dead handle, silently killing the editor→browser direction until a restart. The
    -- callback re-reads the live bufnr from the event so `doc.bufnr` always names the current buffer.
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = grp,
        pattern = doc.file,
        callback = function(ev)
            doc.bufnr = ev.buf
            send_scroll(doc)
        end,
    })
    -- `WinScrolled` is registered SEPARATELY and WITHOUT a pattern, because it does not take a file
    -- one: the event matches its pattern against the WINDOW ID, so `pattern = doc.file` matches
    -- nothing at all and the registration silently never fires (measured in a TUI: pattern-less 2
    -- firings, file pattern 0). It was co-registered with the cursor events here, which is why the
    -- editor→browser link appeared to work — `CursorMoved` was carrying it alone, and a scroll that
    -- left the cursor line alone never reached the page. The gate the pattern would have expressed
    -- is the buffer check inside `send_scroll` (it only acts for the CURRENT buffer).
    api.nvim_create_autocmd("WinScrolled", {
        group = grp,
        callback = function()
            local buf = api.nvim_get_current_buf()
            if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_name(buf) == doc.file then
                doc.bufnr = buf
                send_scroll(doc)
            end
        end,
    })
end

--- Scroll every window in the CURRENT tabpage that shows `file` so `line` is in view.
---
--- The public half of the inbound path, for a producer whose page reports a position this module
--- cannot resolve itself. An ARTIFACT is that case: a PDF page knows a point on a page, and only its
--- producer (lvim-tex, through `synctex edit`) can say which source line that is — but once it has,
--- "put this line in view without disturbing the user" is the same problem the document path already
--- solved, and solving it twice is how the two drift apart. So the resolution stays with the
--- producer and the MOVEMENT stays here, with its three rules intact: move the view and not the
--- cursor, never focus or open a window, never touch a document that is not on screen.
---
--- The caller owns its own anti-oscillation window (it owns the outbound direction too); this
--- function claims nothing and reports nothing.
--- Returns the line that ended up AT THE REFERENCE ROW as well as whether anything moved, and the
--- two are not always the same as the line asked for: with 'wrap' the middle row can belong to the
--- next buffer line, and near the end of a file there is nothing left to scroll. A caller that
--- suppresses its own echo has to compare against what HAPPENED, not against what it requested —
--- otherwise it answers its own placement and the two sides tug at each other.
---@param file string   absolute path of the source file
---@param line integer  1-based
---@param opts { place: ("top"|"center")?, move: ("view"|"cursor")? }?  defaults to `sync_scroll_back`
---@return boolean moved, integer? at  false when no window in this tabpage shows the file
function M.place_source(file, line, opts)
    local target = vim.fs.normalize(vim.fn.fnamemodify(file, ":p"))
    local buf = nil
    for _, b in ipairs(api.nvim_list_bufs()) do
        local name = api.nvim_buf_get_name(b)
        if name ~= "" and vim.fs.normalize(name) == target then
            buf = b
            break
        end
    end
    if not buf or not api.nvim_buf_is_valid(buf) then
        return false
    end
    local wins = visible_windows(buf)
    if #wins == 0 then
        return false
    end
    line = math.max(1, math.min(line, api.nvim_buf_line_count(buf)))
    for _, win in ipairs(wins) do
        place_view(win, buf, line, opts)
    end
    -- Where the FIRST window actually came to rest, measured the same way a follow measures it.
    local at
    local back = vim.tbl_extend("force", config.sync_scroll_back or {}, opts or {})
    api.nvim_win_call(wins[1], function()
        if back.place == "center" then
            local view = vim.fn.winsaveview()
            vim.cmd("keepjumps normal! M")
            at = vim.fn.line(".")
            vim.fn.winrestview(view)
        else
            at = vim.fn.line("w0")
        end
    end)
    return true, at
end

--- Remove ONE document's sync-scroll autocmds.
---@param doc LvimPreviewDoc
---@return nil
function M.detach(doc)
    local name = groups[doc.file]
    if name then
        pcall(api.nvim_del_augroup_by_name, name)
        groups[doc.file] = nil
    end
    last_line[doc.file] = nil
    owner[doc.file] = nil
end

--- Detach every document (server stop / VimLeavePre). The three registries are cleared
--- independently: with `sync_scroll` off there is no augroup, but the inbound direction still
--- leaves a last-line / ownership record behind.
---@return nil
function M.detach_all()
    for path, name in pairs(groups) do
        pcall(api.nvim_del_augroup_by_name, name)
        groups[path] = nil
    end
    last_line = {}
    owner = {}
end

return M
