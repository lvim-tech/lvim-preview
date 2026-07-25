// lvim-preview client — the browser-side dispatcher served by the in-plugin server.
//
// It places or renders the previewed document, re-runs the KaTeX, Mermaid and highlight.js passes,
// and keeps a WebSocket to the editor for live updates. Markdown and org need no renderer here at
// all: both parsers and both HTML renderers are OURS and run in Neovim, so those pages and their
// updates arrive as finished HTML with `server_rendered` set. Markdown and org and raw SVG
// are the only kinds still rendered in the browser. Markdown and org blocks both carry
// `data-source-line` anchors from our renderers, so an editor->browser scroll message can jump to
// the matching element either way.
//
// It is ALSO the viewer for a registered build ARTIFACT — a file some other plugin produced.
// That path renders no document of its own: it fetches the produced file (pdf.js for
// `viewer = "pdf"`, the page itself for `viewer = "html"`) and reacts to the producer's frames
// (`artifact` = refetch, `status` = overlay, `synctex` = scroll + flash).
//
// The browser is a PASSIVE viewer: it sends nothing that drives the editor unless the editor's own
// config opted in. There are exactly two such opt-ins, each with its own server-side gate:
//   * inverse search on a pdf artifact — needs config.artifact.allow_client_messages AND that
//     artifact's own on_message handler;
//   * sync scroll back (this page reporting the source line at the top of its viewport) — needs
//     config.sync_scroll_back.enabled, whose presence in the config block below is what puts this
//     client into two-way mode at all.
(function () {
  "use strict";

  var CFG = window.__lvimPreview || { kind: "html", features: {} };
  var FEAT = CFG.features || {};
  var ART = CFG.artifact || null;
  // { throttle, settle } when the editor enabled browser→editor scroll, else null.
  var BACK = CFG.sync_scroll_back || null;
  var STATIC = "/@lvim-preview/";
  var content = document.getElementById("lp-content");

  // ---- initial content -----------------------------------------------------
  function initialText() {
    var el = document.getElementById("lp-initial");
    if (!el) return "";
    try {
      return JSON.parse(el.textContent);
    } catch (e) {
      return "";
    }
  }


  // ---- post-render passes --------------------------------------------------
  function runKatex() {
    if (FEAT.katex && typeof renderMathInElement !== "undefined") {
      renderMathInElement(content, {
        delimiters: [
          { left: "$$", right: "$$", display: true },
          { left: "$", right: "$", display: false },
          { left: "\\(", right: "\\)", display: false },
          { left: "\\[", right: "\\]", display: true },
        ],
        // User macros from config.features.katex_macros, e.g. { "\\RR": "\\mathbb{R}" }.
        // KaTeX mutates the object it is given (it caches expansions), so hand it a copy —
        // otherwise the second render would see the first one's rewrites.
        macros: Object.assign({}, FEAT.katex_macros || {}),
        throwOnError: false,
      });
    }
  }
  function runMermaid() {
    if (FEAT.mermaid && typeof mermaid !== "undefined") {
      try {
        mermaid.run({ querySelector: ".language-mermaid, .mermaid" });
      } catch (e) {}
    }
  }
  function runHighlight() {
    if (FEAT.highlight && typeof hljs !== "undefined") {
      content.querySelectorAll("pre code:not(.language-mermaid)").forEach(function (el) {
        try {
          hljs.highlightElement(el);
        } catch (e) {}
      });
    }
  }

  // ---- render dispatch -----------------------------------------------------
  // For a kind the plugin renders in Lua (markdown and org — both parsers are ours, in
  // lua/lvim-preview/markdown/ and lua/lvim-preview/org/), the server sends finished HTML and sets
  // `server_rendered`; we place it and run the same post passes, so highlight.js, mermaid and KaTeX
  // apply identically either way. Otherwise `payload` is the DOCUMENT TEXT for a vendored library.
  function render(payload, serverRendered) {
    if (serverRendered) {
      content.innerHTML = payload;
    } else if (CFG.kind === "svg") {
      content.innerHTML = payload;
      return; // svg has no code/math/mermaid passes
    } else {
      return; // html / pdf: the page is not a rendered document
    }
    runHighlight();
    runMermaid();
    runKatex();
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c];
    });
  }

  // ---- theme configuration -------------------------------------------------
  function applyHljsTheme() {
    // Toggle the two github hljs stylesheets by the theme's light/dark hint.
    var scheme = getComputedStyle(document.documentElement).getPropertyValue("--lp-hljs").trim();
    document.querySelectorAll('link[href*="/highlight/github"]').forEach(function (link) {
      var isDark = /github-dark/.test(link.href);
      if (scheme === "dark") link.disabled = !isDark;
      else if (scheme === "light") link.disabled = isDark;
      else link.disabled = false; // auto: let both apply (media not gated) — keep enabled
    });
  }
  function initMermaid() {
    if (FEAT.mermaid && typeof mermaid !== "undefined") {
      var scheme = getComputedStyle(document.documentElement).getPropertyValue("--lp-hljs").trim();
      mermaid.initialize({ startOnLoad: false, securityLevel: "loose", theme: scheme === "dark" ? "dark" : "default" });
    }
  }

  // ---- sync scroll: editor -> browser --------------------------------------
  // One-way mode keeps what it always did: a smooth glide with the block CENTRED.
  // Two-way mode must differ on both counts, and neither is a preference:
  //   * block "start" — the page reports the source line at the TOP of its viewport, so the
  //     editor's top line and the page's top line have to be the same reference point. Centring
  //     here would make every round trip land somewhere new and the two sides would chase.
  //   * behavior "auto" — a smooth animation keeps firing scroll events for hundreds of ms after
  //     the frame that caused it, and an animation's event is indistinguishable from a user's. An
  //     instant jump produces one event we can attribute with certainty.
  var SCROLL_INTO = BACK ? { behavior: "auto", block: "start" } : { behavior: "smooth", block: "center" };

  function scrollToLine(line, total) {
    var nodes = content.querySelectorAll("[data-source-line]");
    if (nodes.length) {
      var target = null;
      for (var i = 0; i < nodes.length; i++) {
        var l = parseInt(nodes[i].getAttribute("data-source-line"), 10);
        if (l >= line) {
          target = nodes[i];
          break;
        }
        target = nodes[i];
      }
      if (target) {
        target.scrollIntoView(SCROLL_INTO);
        return;
      }
    }
    // Fallback: proportional scroll for renderers without source anchors.
    if (total && total > 1) {
      var ratio = (line - 1) / (total - 1);
      window.scrollTo({
        top: ratio * (document.body.scrollHeight - window.innerHeight),
        behavior: SCROLL_INTO.behavior,
      });
    }
  }

  // ---- sync scroll: browser -> editor --------------------------------------
  // Off unless the editor enabled it (BACK). What is reported is the source line at the TOP of the
  // viewport — the same reference point the editor sends outward, which is what makes a round trip
  // a fixed point instead of a chase.
  //
  // Two guards keep this from oscillating with the editor, and they are the client half of the
  // pair the editor keeps (see lua/lvim-preview/scroll.lua):
  //   * `quietUntil` — for `settle` ms after the editor scrolled us, our own scroll events are
  //     ours-because-of-them and are not reported. It is NOT extended by those events, so control
  //     always comes back after one quiet interval.
  //   * `lastLine` — neither side ever sends a line equal to the last one exchanged, so the steady
  //     state after a jump produces no message at all.
  var back = { quietUntil: 0, lastLine: 0, last: 0, timer: null };

  /**
   * The source line at the top of the viewport.
   *
   * Anchors are per BLOCK, so the exact line is only known at a block boundary. Within a block we
   * interpolate, and the assumption is stated rather than hidden: the block's source lines are
   * taken to be spread EVENLY over its rendered height. That holds for wrapped prose and for a
   * code block; it is an approximation for a block whose height comes from something other than
   * its text (an image, a rendered diagram, a math display). The interpolation can never leave the
   * block — it is clamped to the line before the next anchor — so the worst case is exactly the
   * uninterpolated block-level answer.
   */
  function topSourceLine() {
    if (!content) return 0;
    var nodes = content.querySelectorAll("[data-source-line]");
    if (!nodes.length) return 0;
    // Block flow puts a container's top at or above its first child's, and each sibling below the
    // previous one, so tops are non-decreasing in DOM order: the LAST node still at or above the
    // viewport top is the deepest (most precise) anchor owning it.
    var idx = -1;
    var rect = null;
    for (var i = 0; i < nodes.length; i++) {
      var r = nodes[i].getBoundingClientRect();
      if (r.top > 0) break;
      idx = i;
      rect = r;
    }
    if (idx < 0) return parseInt(nodes[0].getAttribute("data-source-line"), 10) || 0;
    var line = parseInt(nodes[idx].getAttribute("data-source-line"), 10);
    if (!line) return 0;
    // The first following anchor on a LATER line bounds this block's line span (a container and
    // its first child share a line, which is why the comparison is strict).
    var next = 0;
    for (var j = idx + 1; j < nodes.length; j++) {
      var nl = parseInt(nodes[j].getAttribute("data-source-line"), 10);
      if (nl > line) {
        next = nl;
        break;
      }
    }
    var span = next ? next - line : 0;
    if (span > 1 && rect && rect.height > 0) {
      var f = Math.min(1, Math.max(0, -rect.top / rect.height));
      line += Math.min(span - 1, Math.floor(f * span));
    }
    return line;
  }

  function reportScroll() {
    if (!BACK || Date.now() < back.quietUntil) return;
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    var line = topSourceLine();
    if (!line || line === back.lastLine) return;
    back.lastLine = line;
    socket.send(JSON.stringify({ type: "scroll_source", path: CFG.path, line: line }));
  }

  // Leading + trailing throttle: a scroll event fires per frame, so report at most every
  // BACK.throttle ms, and always report where the scroll came to rest.
  function onPageScroll() {
    var now = Date.now();
    var wait = BACK.throttle - (now - back.last);
    if (wait <= 0) {
      back.last = now;
      reportScroll();
    } else if (!back.timer) {
      back.timer = setTimeout(function () {
        back.timer = null;
        back.last = Date.now();
        reportScroll();
      }, wait);
    }
  }

  // ---- artifact: producer status overlay ------------------------------------
  // "building" keeps the LAST GOOD render visible under a corner chip — a build takes seconds
  // and blanking the page for each one would make the viewer useless. "error" adds a strip with
  // the producer's first error line; the full diagnostics live in the editor.
  var stallTimer = null;
  function showStatus(state, message, stallMs) {
    var box = document.getElementById("lp-overlay");
    if (!box) return;
    if (stallTimer) {
      clearTimeout(stallTimer);
      stallTimer = null;
    }
    box.className = "lp-overlay-" + state;
    if (state === "building") {
      box.textContent = "building…";
      box.hidden = false;
      var ms = stallMs || (ART && ART.stall_ms) || 10000;
      stallTimer = setTimeout(function () {
        box.textContent = "still building… (" + Math.round(ms / 1000) + "s+)";
      }, ms);
    } else if (state === "error") {
      box.textContent = message || "build failed";
      box.hidden = false;
    } else {
      box.hidden = true;
      box.textContent = "";
    }
  }

  // ---- artifact: the pdf.js viewer -----------------------------------------
  // pdf.js is loaded as an ES module by an inline bootstrap in the shell, which hangs the
  // namespace on window.pdfjsLib and fires "lp-pdfjs". Both orders are handled: the flag may
  // already be set by the time this deferred script runs.
  // pdf.pages[i] = { num, page (proxy), wrap (div), vp (viewport), canvas (or null), task (or null) }.
  // A page's wrap is a correctly-SIZED placeholder from load; `canvas` exists only while the page
  // is painted (see the lazy machinery below).
  var pdf = { doc: null, scale: 1.25, loading: false, pages: [], observer: null };

  function pdfLib(cb) {
    if (window.pdfjsLib) return cb(window.pdfjsLib);
    window.addEventListener("lp-pdfjs", function () {
      cb(window.pdfjsLib);
    });
  }

  function artifactFileUrl() {
    return "./" + encodeURIComponent(ART.file) + "?g=" + ART.generation;
  }

  /** Where the reader is: the top visible page and the pixel offset into it (survives a page-count change). */
  function capturePosition() {
    var pages = document.querySelectorAll("#lp-pdf .lp-page");
    for (var i = 0; i < pages.length; i++) {
      var r = pages[i].getBoundingClientRect();
      if (r.bottom > 0) {
        return { page: i + 1, offset: -r.top, scale: pdf.scale };
      }
    }
    return { page: 1, offset: 0, scale: pdf.scale };
  }

  /** 0-based index of the page at the top of the viewport — the centre lazy rendering keeps around. */
  function currentPageIndex() {
    return capturePosition().page - 1;
  }

  function restorePosition(pos) {
    if (!pos) return;
    var p = pdf.pages[pos.page - 1];
    if (!p) return;
    window.scrollTo({ top: p.wrap.offsetTop + pos.offset, behavior: "auto" });
  }

  // ---- lazy page machinery -------------------------------------------------
  // Every page gets a correctly-sized placeholder on load (its viewport is cheap — no
  // rasterisation), but the <canvas> is painted only when the page nears the viewport and is
  // released again when it scrolls far away, so a long PDF never holds one canvas per page. Because
  // the placeholder keeps its exact height either way, scroll position, position-restore across a
  // producer reload and forward-search all address a STABLE layout whether or not a page is painted.

  /** Paint page `num` (1-based) into its placeholder, unless already painted or a render is in flight. */
  function ensureRendered(num) {
    var p = pdf.pages[num - 1];
    if (!p || p.canvas || p.task) return;
    var dpr = window.devicePixelRatio || 1;
    var canvas = document.createElement("canvas");
    canvas.width = Math.floor(p.vp.width * dpr);
    canvas.height = Math.floor(p.vp.height * dpr);
    canvas.style.width = p.vp.width + "px";
    canvas.style.height = p.vp.height + "px";
    p.wrap.appendChild(canvas);
    p.canvas = canvas;
    p.task = p.page.render({
      canvasContext: canvas.getContext("2d"),
      viewport: p.page.getViewport({ scale: pdf.scale * dpr }),
    });
    p.task.promise.then(
      function () {
        p.task = null;
      },
      function () {
        // Cancelled (released mid-render) or failed: drop the half-canvas so a return re-renders it.
        if (p.canvas && p.canvas.parentNode) p.canvas.parentNode.removeChild(p.canvas);
        p.canvas = null;
        p.task = null;
      }
    );
  }

  /** Drop page `p`'s canvas (cancelling an in-flight render) and free its backing bitmap. */
  function releaseCanvas(p) {
    if (p.task) {
      try {
        p.task.cancel();
      } catch (e) {}
      p.task = null;
    }
    if (p.canvas) {
      if (p.canvas.parentNode) p.canvas.parentNode.removeChild(p.canvas);
      // Zero the backing store so the browser reclaims the bitmap now, not at some later GC.
      p.canvas.width = 0;
      p.canvas.height = 0;
      p.canvas = null;
    }
  }

  /** Keep at most `max_canvases` painted pages — the ones nearest the viewport; release the rest. */
  function trimCanvases() {
    var max = ART.max_canvases;
    if (!(max > 0)) return;
    var live = [];
    for (var i = 0; i < pdf.pages.length; i++) {
      var p = pdf.pages[i];
      if (p && (p.canvas || p.task)) live.push(p);
    }
    if (live.length <= max) return;
    var centre = currentPageIndex();
    live.sort(function (a, b) {
      return Math.abs(a.num - 1 - centre) - Math.abs(b.num - 1 - centre);
    });
    for (var j = max; j < live.length; j++) releaseCanvas(live[j]);
  }

  function setupObserver() {
    if (pdf.observer) pdf.observer.disconnect();
    // rootMargin grows the viewport by `lookahead` pages each way, so the page just past the fold
    // is painted before it is scrolled into view and scrolling stays smooth.
    var avg = pdf.pages.length ? pdf.pages[0].vp.height : 800;
    var margin = Math.round(avg * (ART.lookahead || 0));
    pdf.observer = new IntersectionObserver(
      function (entries) {
        var painted = false;
        for (var i = 0; i < entries.length; i++) {
          if (entries[i].isIntersecting) {
            ensureRendered(parseInt(entries[i].target.getAttribute("data-page"), 10));
            painted = true;
          }
        }
        if (painted) trimCanvases();
      },
      { root: null, rootMargin: margin + "px 0px " + margin + "px 0px", threshold: 0 }
    );
    for (var k = 0; k < pdf.pages.length; k++) pdf.observer.observe(pdf.pages[k].wrap);
  }

  /**
   * Lay out placeholders for every page of `doc` at the current scale, restore `pos`, then either
   * wire the IntersectionObserver (lazy) or paint every page (eager). Resolves when the layout is up.
   */
  function layoutPages(doc, pos) {
    if (pdf.observer) {
      pdf.observer.disconnect();
      pdf.observer = null;
    }
    pdf.pages = [];
    var host = document.getElementById("lp-pdf");
    var frag = document.createDocumentFragment();
    var chain = Promise.resolve();
    for (var n = 1; n <= doc.numPages; n++) {
      (function (num) {
        chain = chain.then(function () {
          return doc.getPage(num).then(function (page) {
            var vp = page.getViewport({ scale: pdf.scale });
            var wrap = document.createElement("div");
            wrap.className = "lp-page";
            wrap.setAttribute("data-page", String(num));
            wrap.style.width = vp.width + "px";
            wrap.style.height = vp.height + "px";
            frag.appendChild(wrap);
            pdf.pages[num - 1] = { num: num, page: page, wrap: wrap, vp: vp, canvas: null, task: null };
          });
        });
      })(n);
    }
    return chain.then(function () {
      host.innerHTML = "";
      host.appendChild(frag);
      restorePosition(pos);
      if (ART.lazy) {
        // The observer paints whatever is visible (plus lookahead) as soon as layout settles.
        setupObserver();
      } else {
        // Eager: paint every page and keep them all (the pre-lazy behaviour, opt-in).
        for (var i = 1; i <= doc.numPages; i++) ensureRendered(i);
      }
      showStatus("ok");
    });
  }

  function renderPdf(preserve) {
    if (!ART || pdf.loading) return;
    pdf.loading = true;
    var pos = preserve && ART.restore_position ? capturePosition() : null;
    pdfLib(function (lib) {
      var task = lib.getDocument({
        url: artifactFileUrl(),
        // Everything below is vendored beside the library so the page fetches NOTHING from a CDN,
        // and every one is loaded strictly ON DEMAND — a plain-Latin PDF pulls none of them:
        //   standard_fonts/  the 14 base PDF fonts (used when a font is not embedded);
        //   cmaps/           packed .bcmap CJK character maps (a CID-keyed CJK font needs one);
        //   wasm/            the JPEG-2000 / JBIG2 image decoders + the ICC colour transform.
        standardFontDataUrl: STATIC + "vendor/pdfjs/standard_fonts/",
        cMapUrl: STATIC + "vendor/pdfjs/cmaps/",
        cMapPacked: true,
        wasmUrl: STATIC + "vendor/pdfjs/wasm/",
      });
      task.promise.then(
        function (doc) {
          pdf.doc = doc;
          layoutPages(doc, pos)
            .then(function () {
              pdf.loading = false;
            })
            .catch(function () {
              pdf.loading = false;
            });
        },
        function () {
          // Not produced yet, or produced but unreadable: leave the previous render in place.
          pdf.loading = false;
        }
      );
    });
  }

  function zoom(delta) {
    if (!pdf.doc || pdf.loading) return;
    var pos = capturePosition();
    var old = pdf.scale;
    pdf.scale = Math.min(6, Math.max(0.25, delta === 0 ? 1.25 : pdf.scale + delta));
    pdf.loading = true;
    // Re-lay the placeholders at the new scale and land on the same content — the pixel offset
    // scales with the zoom ratio. getPage is cached, so this is cheap; only visible pages repaint.
    layoutPages(pdf.doc, { page: pos.page, offset: pos.offset * (pdf.scale / old), scale: pdf.scale })
      .then(function () {
        pdf.loading = false;
      })
      .catch(function () {
        pdf.loading = false;
      });
  }

  /**
   * Forward search: scroll page `page` into view and flash a rect. `x`/`y`/`width`/`height` are
   * PDF points from the TOP-LEFT of the page — the coordinate space `synctex view` reports — so
   * they scale by exactly the viewport scale. With lazy rendering the target page may not be
   * painted yet: paint it now so the glyphs are there when we land. The canvas budget is left to
   * the observer that fires on arrival (so the target we just painted is never the one trimmed).
   */
  function synctexTo(msg) {
    var el = document.querySelector('#lp-pdf .lp-page[data-page="' + msg.page + '"]');
    if (!el) return;
    ensureRendered(msg.page);
    var rect = document.createElement("div");
    rect.className = "lp-synctex";
    rect.style.left = (msg.x || 0) * pdf.scale + "px";
    rect.style.top = (msg.y || 0) * pdf.scale + "px";
    rect.style.width = (msg.width ? msg.width * pdf.scale : el.clientWidth - (msg.x || 0) * pdf.scale) + "px";
    rect.style.height = (msg.height ? msg.height * pdf.scale : 14 * pdf.scale) + "px";
    el.appendChild(rect);
    rect.scrollIntoView({ behavior: "smooth", block: "center" });
    setTimeout(
      function () {
        if (rect.parentNode) rect.parentNode.removeChild(rect);
      },
      msg.highlight_ms || (ART && ART.highlight_ms) || 1200
    );
  }

  /**
   * Inverse search. Sent ONLY on ctrl-click and ONLY when the server told us inbound messages
   * are enabled; the server then delivers it only to an artifact whose producer registered an
   * on_message handler. This is the one thing the page ever sends.
   */
  function sendSynctexEdit(ev) {
    if (!ev.ctrlKey || !ART || !ART.allow_client_messages) return;
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    var el = ev.target.closest ? ev.target.closest(".lp-page") : null;
    if (!el) return;
    var r = el.getBoundingClientRect();
    socket.send(
      JSON.stringify({
        type: "synctex_edit",
        path: CFG.path,
        page: parseInt(el.getAttribute("data-page"), 10),
        x: (ev.clientX - r.left) / pdf.scale,
        y: (ev.clientY - r.top) / pdf.scale,
      })
    );
    ev.preventDefault();
  }

  // ---- WebSocket -----------------------------------------------------------
  var socket = null;
  var wasConnected = false;
  function wsUrl() {
    var proto = window.location.protocol === "https:" ? "wss:" : "ws:";
    return proto + "//" + window.location.host + "/";
  }
  function pathMatches(p) {
    if (!p) return true;
    // CFG.path is what the SERVER said this page renders — authoritative, and correct even when the
    // page was opened at the bare root "/" (which serves a document but leaves location.pathname "/").
    // Comparing location.pathname alone breaks exactly that case: a root-opened tab would ignore its
    // own document's update / scroll frames (theme frames are pathless, so they still applied — which
    // is why the theme changed everywhere but live edits did not). Fall back to the location check.
    if (CFG.path && p === CFG.path) return true;
    try {
      return decodeURIComponent(window.location.pathname) === p || decodeURIComponent(window.location.pathname).endsWith(p);
    } catch (e) {
      return true;
    }
  }
  function connect() {
    socket = new WebSocket(wsUrl());
    socket.onopen = function () {
      if (wasConnected) {
        // Reconnected after the server restarted — reload for a fresh shell.
        window.location.reload();
      }
      wasConnected = true;
    };
    socket.onmessage = function (ev) {
      var msg;
      try {
        msg = JSON.parse(ev.data);
      } catch (e) {
        return;
      }
      if (msg.type === "reload") {
        window.location.reload();
      } else if (msg.type === "update") {
        if (pathMatches(msg.path)) render(msg.content, msg.server_rendered === true);
      } else if (msg.type === "scroll") {
        if (pathMatches(msg.path)) {
          if (BACK) {
            // The editor owns the sync for `settle` ms: the scroll event our own jump is about to
            // fire is its echo, not the reader moving the page.
            back.quietUntil = Date.now() + BACK.settle;
            back.lastLine = msg.line;
          }
          scrollToLine(msg.line, msg.total);
        }
      } else if (msg.type === "artifact") {
        // The producer says the file is new and coherent. Bump our cache-bust token and
        // refetch; a pdf viewer re-renders in place, any other artifact page reloads.
        if (ART && pathMatches(msg.path)) {
          ART.generation = msg.generation;
          if (CFG.kind === "pdf") renderPdf(true);
          else window.location.reload();
        }
      } else if (msg.type === "status") {
        if (ART && pathMatches(msg.path)) showStatus(msg.state, msg.message, msg.stall_ms);
      } else if (msg.type === "synctex") {
        if (ART && CFG.kind === "pdf" && pathMatches(msg.path)) synctexTo(msg);
      } else if (msg.type === "theme") {
        var style = document.getElementById("lp-theme");
        if (style) style.textContent = msg.css;
        applyHljsTheme();
        initMermaid();
      }
    };
    socket.onclose = function () {
      wasConnected = wasConnected; // keep flag; reconnect loop below reloads on reopen
    };
    socket.onerror = function () {
      try {
        socket.close();
      } catch (e) {}
    };
  }

  // ---- boot ----------------------------------------------------------------
  window.addEventListener("load", function () {
    applyHljsTheme();
    initMermaid();
    if (ART) {
      if (ART.status && ART.status !== "idle") showStatus(ART.status, ART.message);
      if (CFG.kind === "pdf") {
        renderPdf(false);
        document.addEventListener("click", sendSynctexEdit);
        document.addEventListener("keydown", function (ev) {
          if (ev.ctrlKey || ev.metaKey || ev.altKey) return;
          if (ev.key === "+" || ev.key === "=") zoom(0.25);
          else if (ev.key === "-") zoom(-0.25);
          else if (ev.key === "0") zoom(0);
        });
      }
    } else if (CFG.kind !== "html") {
      render(initialText(), CFG.server_rendered === true);
    }
    // Only a DOCUMENT page reports scrolls: an artifact has no source lines to report.
    if (BACK && !ART && content) {
      window.addEventListener("scroll", onPageScroll, { passive: true });
    }
    connect();
    // Reconnect poll: if the socket dropped, try again (onopen reloads the page).
    setInterval(function () {
      if (!socket || socket.readyState === WebSocket.CLOSED) connect();
    }, 1000);
  });
})();
