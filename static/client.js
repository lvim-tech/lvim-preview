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

  // ---- artifact: report where the reader is (pdf -> producer) ---------------
  // The document reporter above answers "which SOURCE LINE is at the top"; an artifact has no
  // source lines, so this one answers the only thing a PDF page knows: WHICH POINT of which page is
  // at the top of the viewport. Turning that into a place in the source is SyncTeX's job and belongs
  // to the producer, which owns the .synctex.gz — the page must not pretend to know.
  //
  // Gated on the same `allow_client_messages` as ctrl-click inverse search: one switch for "this
  // page may talk back". Whether the frames are acted upon is the producer's decision, not ours.
  //
  // The same two anti-oscillation guards as the document path, for the same reasons: a quiet window
  // after the producer scrolled us (so its own scroll is not reported straight back), and never
  // sending a position equal to the last one sent.
  var artBack = { quietUntil: 0, last: 0, timer: null, lastKey: "" };
  // Both are POLICY, and the document link already exposes its equivalents — a hardcoded pair here
  // is how the two halves of one link drift into disagreeing about timing, which is exactly the
  // shape of the echo regression this file already carries scar tissue from. Correctness does not
  // rest on the numbers matching (value and generation guards do that), but the policy has to be
  // inspectable and tunable.
  function artThrottle() {
    return typeof ART.scroll_throttle === "number" ? ART.scroll_throttle : 80;
  }
  function artSettle() {
    return typeof ART.scroll_settle === "number" ? ART.scroll_settle : 400;
  }

  /**
   * Where the reader is, as the page that CONTAINS the anchor line and the offset into it.
   *
   * NOT the top edge of the viewport, and that is the whole precision of this direction. A typeset
   * page opens with a margin — on A4 the first ~170 PDF points carry nothing — and a point in a
   * margin has no text under it, so the producer's SyncTeX lookup snaps to whatever record is
   * nearest by its own metric, which is routinely a paragraph on another page. The top edge sits in
   * that margin through the whole of every page transition; the anchor (the viewport centre by
   * default) only does while a boundary crosses the middle of the screen.
   *
   * The offset is CLAMPED into the page as well: pages are separated by a visual gap, and with the
   * reference point inside it the old code picked the page BELOW and reported a negative offset —
   * a coordinate that cannot mean anything to SyncTeX.
   */
  function anchorPosition() {
    var f = typeof ART.scroll_anchor === "number" ? ART.scroll_anchor : 0.5;
    var anchorY = window.innerHeight * Math.min(1, Math.max(0, f));
    var pages = document.querySelectorAll("#lp-pdf .lp-page");
    for (var i = 0; i < pages.length; i++) {
      var r = pages[i].getBoundingClientRect();
      if (r.top <= anchorY && r.bottom > anchorY) {
        return { page: i + 1, offset: anchorY - r.top, height: r.height };
      }
    }
    // The anchor is in the GAP between two pages (or off either end): report NOTHING. A gap has no
    // content to read, and the only positions available there are the page EDGES — which is where a
    // typeset page's margin is, the one band whose lookup resolves to an arbitrary paragraph. The
    // previous mid-page report simply stays current for the fraction of a second a boundary takes to
    // cross the anchor; reporting an edge instead is what made the source jump to the foot of the
    // page and snap back on every page transition.
    return null;
  }

  function reportArtifactScroll() {
    if (!ART || CFG.kind !== "pdf" || !ART.allow_client_messages) return;
    if (Date.now() < artBack.quietUntil) return;
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    var pos = anchorPosition();
    if (!pos) return;
    // PDF points from the page's top-left — the same contract as the inbound `synctex` frame, so a
    // round trip through the producer is symmetric. The page is laid out at `scale` CSS px per PDF
    // point, so dividing by it is the whole conversion.
    var y = Math.max(0, Math.min(pos.offset, pos.height)) / pdf.scale;
    var x = typeof ART.scroll_x === "number" ? ART.scroll_x : 40;
    var key = pos.page + ":" + Math.round(y);
    if (key === artBack.lastKey) return;
    // Marked delivered only once it HAS been: `readyState` can change between the check above and
    // the call, and `send` can throw. Recording the key first would retire a position that never
    // left, and nothing would resend it until the anchor moved again.
    try {
      socket.send(JSON.stringify({ type: "synctex_scroll", path: CFG.path, page: pos.page, x: x, y: y }));
      artBack.lastKey = key;
    } catch (e) {
      /* not delivered: leave the baseline alone so the next tick retries */
    }
  }

  function onArtifactScroll() {
    var now = Date.now();
    var wait = artThrottle() - (now - artBack.last);
    if (wait <= 0) {
      artBack.last = now;
      reportArtifactScroll();
    } else if (!artBack.timer) {
      artBack.timer = setTimeout(function () {
        artBack.timer = null;
        artBack.last = Date.now();
        reportArtifactScroll();
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
  // pdf.pages[i] = { num, page (proxy), wrap (div), vp (viewport), canvas, task, text (the selectable
  // text-layer div), textLayer (its pdf.js object) } — everything after `vp` is null while unpainted.
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

  /**
   * Put the reader back where they were after a re-layout — a producer reload, or a zoom.
   *
   * THIS IS NOT THE READER SCROLLING, and the difference is not cosmetic: the scroll events it
   * raises are indistinguishable from a real one, so without the quiet window a successful BUILD
   * would report a position and move the editor's source, purely because the PDF was re-rendered.
   * The dedupe baseline is reset from where we land rather than sent, so the next genuine scroll is
   * measured against the restored position instead of the pre-layout one.
   */
  function restorePosition(pos) {
    if (!pos) return;
    var p = pdf.pages[pos.page - 1];
    if (!p) return;
    artBack.quietUntil = Date.now() + artSettle();
    window.scrollTo({ top: p.wrap.offsetTop + pos.offset, behavior: "auto" });
    var here = anchorPosition();
    artBack.lastKey = here ? here.page + ":" + Math.round(Math.max(0, Math.min(here.offset, here.height)) / pdf.scale) : "";
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
    // THE PAGE IS SELECTABLE ONLY BECAUSE OF THIS. A canvas is pixels: it carries no text, so
    // nothing on it can be selected, searched with the browser's own find, or copied. pdf.js's
    // TextLayer is the mechanism for that — transparent, absolutely positioned spans laid over the
    // canvas at the glyph positions — and it is rendered per page, released with the canvas.
    //
    // Its viewport is the CSS one (`pdf.scale`), not the canvas's device-pixel viewport: the spans
    // are laid out in CSS pixels against `--total-scale-factor` on the wrap.
    if (window.pdfjsLib && window.pdfjsLib.TextLayer) {
      var tdiv = document.createElement("div");
      tdiv.className = "lp-text";
      p.wrap.appendChild(tdiv);
      p.text = tdiv;
      try {
        p.textLayer = new window.pdfjsLib.TextLayer({
          textContentSource: p.page.streamTextContent(),
          container: tdiv,
          viewport: p.page.getViewport({ scale: pdf.scale }),
        });
        p.textLayer.render().catch(function () {});
        // The `.endOfContent` marker is NOT created by the low-level TextLayer we use — pdf.js's own
        // viewer component makes it, and everything that depends on it (a highlight running to the
        // edge of a justified line; a drag into empty space not swallowing the rest of the page)
        // lives in that component. So the element is created here and driven by `bindSelection`.
        var endDiv = document.createElement("div");
        endDiv.className = "endOfContent";
        tdiv.append(endDiv);
        p.endOfContent = endDiv;
        textLayers.set(tdiv, endDiv);
        bindSelection();
      } catch (e) {
        p.textLayer = null;
      }
    }
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

  // ---- text selection across the pages ---------------------------------------
  // Ported from pdf.js's own TextLayerBuilder, because the behaviour lives THERE and not in the
  // TextLayer class this file uses. Two things depend on it:
  //
  //   * a highlight that runs to the edge of a justified line instead of stopping at its last glyph
  //     (that is what the `.endOfContent` marker, lifted to cover the layer while a drag is in
  //     progress, is for);
  //   * a drag that wanders into the MARGIN not swallowing everything down to the end of the page.
  //     Outside Firefox, hovering empty space means hovering `.endOfContent`, and the browser then
  //     extends the selection all the way to it. Moving that element to sit right beside the end the
  //     user is dragging bounds the jump to the span being modified — which is the whole trick, and
  //     it cannot be expressed in CSS.
  var textLayers = new Map();
  var selectionBound = false;

  function resetLayer(endDiv, layer) {
    if (endDiv) {
      layer.append(endDiv);
      endDiv.style.width = "";
      endDiv.style.height = "";
    }
    layer.classList.remove("lp-selecting");
  }

  function bindSelection() {
    if (selectionBound) return;
    selectionBound = true;
    var pointerDown = false;
    var prevRange = null;
    var resetAll = function () {
      textLayers.forEach(function (endDiv, layer) {
        resetLayer(endDiv, layer);
      });
    };
    document.addEventListener("pointerdown", function () {
      pointerDown = true;
    });
    document.addEventListener("pointerup", function () {
      pointerDown = false;
      resetAll();
    });
    window.addEventListener("blur", function () {
      pointerDown = false;
      resetAll();
    });
    document.addEventListener("keyup", function () {
      if (!pointerDown) resetAll();
    });
    document.addEventListener("selectionchange", function () {
      var selection = document.getSelection();
      if (!selection || selection.rangeCount === 0) {
        resetAll();
        return;
      }
      var active = new Set();
      for (var i = 0; i < selection.rangeCount; i++) {
        var r = selection.getRangeAt(i);
        textLayers.forEach(function (_end, layer) {
          if (!active.has(layer) && r.intersectsNode(layer)) active.add(layer);
        });
      }
      textLayers.forEach(function (endDiv, layer) {
        if (active.has(layer)) layer.classList.add("lp-selecting");
        else resetLayer(endDiv, layer);
      });

      var range = selection.getRangeAt(0);
      // Which END is being dragged: if this range shares its end with the previous one, the user is
      // moving the START. The marker goes on that side, so the bounded jump is on the side that moves.
      var modifyStart =
        prevRange &&
        (range.compareBoundaryPoints(Range.END_TO_END, prevRange) === 0 ||
          range.compareBoundaryPoints(Range.START_TO_END, prevRange) === 0);
      var anchorNode = modifyStart ? range.startContainer : range.endContainer;
      if (anchorNode.nodeType === Node.TEXT_NODE) anchorNode = anchorNode.parentNode;
      if (!modifyStart && range.endOffset === 0) {
        try {
          do {
            while (!anchorNode.previousSibling) anchorNode = anchorNode.parentNode;
            anchorNode = anchorNode.previousSibling;
          } while (!anchorNode.childNodes.length);
        } catch (e) {
          anchorNode = null;
        }
      }
      var parentLayer = anchorNode && anchorNode.parentElement && anchorNode.parentElement.closest(".lp-text");
      var endDiv = parentLayer && textLayers.get(parentLayer);
      if (endDiv) {
        endDiv.style.width = parentLayer.style.width;
        endDiv.style.height = parentLayer.style.height;
        endDiv.style.userSelect = "text";
        anchorNode.parentElement.insertBefore(endDiv, modifyStart ? anchorNode : anchorNode.nextSibling);
      }
      prevRange = range.cloneRange();
    });
  }

  /** Drop page `p`'s canvas (cancelling an in-flight render) and free its backing bitmap. */
  function releaseCanvas(p) {
    // The text layer belongs to the painted page: a released placeholder shows nothing, so leaving
    // its spans behind would keep selectable text floating over a blank page.
    if (p.textLayer) {
      try {
        if (typeof p.textLayer.cancel === "function") p.textLayer.cancel();
      } catch (e) {}
      p.textLayer = null;
    }
    if (p.text) {
      textLayers.delete(p.text);
      if (p.text.parentNode) p.text.parentNode.removeChild(p.text);
      p.text = null;
      p.endOfContent = null;
    }
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
            // pdf.js sizes and positions the text layer against this custom property, so it must
            // carry the CSS scale (not the device-pixel one the canvas is painted at). Set on the
            // wrap at layout, which zooming redoes wholesale — so the text stays over its glyphs.
            wrap.style.setProperty("--total-scale-factor", String(pdf.scale));
            frag.appendChild(wrap);
            pdf.pages[num - 1] = { num: num, page: page, wrap: wrap, vp: vp, canvas: null, task: null, text: null, textLayer: null, endOfContent: null };
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
  /**
   * The ONE live forward-search highlight, and the timer that will remove it. There is deliberately
   * never a second: a producer that syncs continuously (an editor following the cursor) sends a frame
   * every few hundred ms, and with a per-rect timer each one lived out its own 1200 ms — so the page
   * accumulated a stack of translucent bands at the positions it had passed through. A newer target
   * SUPERSEDES the older one; that is also the truthful reading, since only one place is current.
   */
  var synctexRect = null;
  var synctexTimer = null;

  function clearSynctex() {
    // `!== null`, not truthiness: a timer HANDLE of 0 is legal (and the first one a fresh page hands
    // out can be exactly that), so `if (synctexTimer)` would leave the very first highlight's timer
    // running and let it delete a newer rect out from under the viewer.
    if (synctexTimer !== null) {
      clearTimeout(synctexTimer);
      synctexTimer = null;
    }
    if (synctexRect && synctexRect.parentNode) synctexRect.parentNode.removeChild(synctexRect);
    synctexRect = null;
    // Belt for a rect left by an earlier page render (a reload replaces .lp-page nodes wholesale, so
    // a rect can outlive the element this closure remembered).
    var stale = document.querySelectorAll("#lp-pdf .lp-synctex");
    for (var i = 0; i < stale.length; i++) {
      if (stale[i].parentNode) stale[i].parentNode.removeChild(stale[i]);
    }
  }

  function synctexTo(msg) {
    var el = document.querySelector('#lp-pdf .lp-page[data-page="' + msg.page + '"]');
    if (!el) return;
    // The producer is moving us: the scroll events this causes are ours-because-of-it and must not
    // be reported back. Set BEFORE the scroll, and not extended by the events it produces, so
    // control returns to the reader after one quiet interval.
    artBack.quietUntil = Date.now() + artSettle();
    ensureRendered(msg.page);
    clearSynctex();
    // `0` means NO band — scroll there and leave the page alone. Resolved with explicit null checks
    // for the same reason the timer guard uses them: `a || b` cannot express a deliberate zero, so
    // `highlight_ms = 0` used to fall through to the 1200 ms default and there was no way to turn the
    // flash off. A producer that syncs continuously is exactly who wants that.
    var ms = msg.highlight_ms;
    if (ms === undefined || ms === null) ms = ART && ART.highlight_ms;
    if (ms === undefined || ms === null) ms = 1200;
    if (!(ms > 0)) {
      el.scrollIntoView({ behavior: "smooth", block: "center" });
      return;
    }
    var rect = document.createElement("div");
    rect.className = "lp-synctex";
    rect.style.left = (msg.x || 0) * pdf.scale + "px";
    rect.style.top = (msg.y || 0) * pdf.scale + "px";
    rect.style.width = (msg.width ? msg.width * pdf.scale : el.clientWidth - (msg.x || 0) * pdf.scale) + "px";
    rect.style.height = (msg.height ? msg.height * pdf.scale : 14 * pdf.scale) + "px";
    el.appendChild(rect);
    synctexRect = rect;
    rect.scrollIntoView({ behavior: "smooth", block: "center" });
    synctexTimer = setTimeout(function () {
      clearSynctex();
    }, ms);
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
    // Upgrade on the page's OWN path, not on "/": that is what lets the server know which document
    // or artifact this socket belongs to and send it only what concerns it. Connecting to the root
    // made every client a subscriber to everything, and the filtering happened here — after the
    // metadata had already crossed the network.
    return proto + "//" + window.location.host + window.location.pathname;
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
    // A new socket has delivered nothing yet: the dedupe baseline describes a conversation that no
    // longer exists.
    artBack.lastKey = "";
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
    // A DOCUMENT page reports source lines; a pdf ARTIFACT page reports a point on a page, which
    // only its producer can turn into a place in the source. Different reporters, same throttle.
    if (BACK && !ART && content) {
      window.addEventListener("scroll", onPageScroll, { passive: true });
    } else if (ART && CFG.kind === "pdf" && ART.allow_client_messages) {
      window.addEventListener("scroll", onArtifactScroll, { passive: true });
    }
    connect();
    // Reconnect poll: if the socket dropped, try again (onopen reloads the page).
    setInterval(function () {
      if (!socket || socket.readyState === WebSocket.CLOSED) connect();
    }, 1000);
  });
})();
