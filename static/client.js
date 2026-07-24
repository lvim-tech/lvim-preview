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
// The browser is a PASSIVE viewer: it never sends anything that drives the editor. The single
// exception is inverse search on a pdf artifact, which requires BOTH the server-side config gate
// (config.artifact.allow_client_messages) and the artifact's own on_message handler.
(function () {
  "use strict";

  var CFG = window.__lvimPreview || { kind: "html", features: {} };
  var FEAT = CFG.features || {};
  var ART = CFG.artifact || null;
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

  // ---- sync scroll ---------------------------------------------------------
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
        target.scrollIntoView({ behavior: "smooth", block: "center" });
        return;
      }
    }
    // Fallback: proportional scroll for renderers without source anchors.
    if (total && total > 1) {
      var ratio = (line - 1) / (total - 1);
      window.scrollTo({ top: ratio * (document.body.scrollHeight - window.innerHeight), behavior: "smooth" });
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
  var pdf = { doc: null, scale: 1.25, busy: false };

  function pdfLib(cb) {
    if (window.pdfjsLib) return cb(window.pdfjsLib);
    window.addEventListener("lp-pdfjs", function () {
      cb(window.pdfjsLib);
    });
  }

  function artifactFileUrl() {
    return "./" + encodeURIComponent(ART.file) + "?g=" + ART.generation;
  }

  /** Where the reader is: the top visible page and the offset inside it (survives a page-count change). */
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

  function restorePosition(pos) {
    if (!pos) return;
    var el = document.querySelector('#lp-pdf .lp-page[data-page="' + pos.page + '"]');
    if (!el) return;
    window.scrollTo({ top: el.offsetTop + pos.offset, behavior: "auto" });
  }

  function renderPdf(preserve) {
    if (!ART || pdf.busy) return;
    pdf.busy = true;
    var pos = preserve && ART.restore_position ? capturePosition() : null;
    pdfLib(function (lib) {
      var task = lib.getDocument({
        url: artifactFileUrl(),
        // The 14 standard PDF fonts are vendored beside the library; without this pdf.js would
        // reach for a CDN, which the offline guarantee forbids.
        standardFontDataUrl: STATIC + "vendor/pdfjs/standard_fonts/",
      });
      task.promise.then(
        function (doc) {
          pdf.doc = doc;
          var host = document.getElementById("lp-pdf");
          var frag = document.createDocumentFragment();
          var dpr = window.devicePixelRatio || 1;
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
                  var canvas = document.createElement("canvas");
                  canvas.width = Math.floor(vp.width * dpr);
                  canvas.height = Math.floor(vp.height * dpr);
                  canvas.style.width = vp.width + "px";
                  canvas.style.height = vp.height + "px";
                  wrap.appendChild(canvas);
                  frag.appendChild(wrap);
                  return page.render({
                    canvasContext: canvas.getContext("2d"),
                    viewport: page.getViewport({ scale: pdf.scale * dpr }),
                  }).promise;
                });
              });
            })(n);
          }
          chain
            .then(function () {
              host.innerHTML = "";
              host.appendChild(frag);
              restorePosition(pos);
              showStatus("ok");
              pdf.busy = false;
            })
            .catch(function () {
              pdf.busy = false;
            });
        },
        function () {
          // Not produced yet, or produced but unreadable: leave the previous render in place.
          pdf.busy = false;
        }
      );
    });
  }

  function zoom(delta) {
    var pos = capturePosition();
    pdf.scale = Math.min(6, Math.max(0.25, delta === 0 ? 1.25 : pdf.scale + delta));
    renderPdf(false);
    // renderPdf clears `pos` capture; restore against the NEW layout once it settled.
    setTimeout(function () {
      restorePosition({ page: pos.page, offset: pos.offset * (pdf.scale / pos.scale) });
    }, 60);
  }

  /**
   * Forward search: scroll page `page` into view and flash a rect. `x`/`y`/`width`/`height` are
   * PDF points from the TOP-LEFT of the page — the coordinate space `synctex view` reports — so
   * they scale by exactly the viewport scale.
   */
  function synctexTo(msg) {
    var el = document.querySelector('#lp-pdf .lp-page[data-page="' + msg.page + '"]');
    if (!el) return;
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
        if (pathMatches(msg.path)) scrollToLine(msg.line, msg.total);
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
    connect();
    // Reconnect poll: if the socket dropped, try again (onopen reloads the page).
    setInterval(function () {
      if (!socket || socket.readyState === WebSocket.CLOSED) connect();
    }, 1000);
  });
})();
