// lvim-preview client — the browser-side dispatcher served by the in-plugin server.
//
// It renders the previewed document (markdown-it / asciidoctor.js / raw SVG), re-runs the
// KaTeX, Mermaid and highlight.js passes, and keeps a WebSocket to the editor for live
// updates. Markdown blocks are tagged with `data-source-line` (via markdown-it's token API)
// so an editor->browser scroll message can jump to the matching element. The browser is a
// PASSIVE viewer: it never sends anything that drives the editor.
(function () {
  "use strict";

  var CFG = window.__lvimPreview || { kind: "html", features: {} };
  var FEAT = CFG.features || {};
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

  // ---- markdown-it setup ---------------------------------------------------
  var md = null;
  function buildMarkdown() {
    if (typeof window.markdownit === "undefined") return null;
    var inst = window.markdownit({
      html: true,
      linkify: true,
      typographer: true,
      highlight: function (str, lang) {
        if (FEAT.highlight && typeof hljs !== "undefined" && lang && hljs.getLanguage(lang)) {
          try {
            return hljs.highlight(str, { language: lang }).value;
          } catch (e) {}
        }
        return "";
      },
    });
    // Emit source-line anchors on block-level tokens for sync scroll. Only the *_open (and
    // table_open) tokens are wrapped: those render through renderToken, so tagging the token
    // and delegating is safe. Tokens with a CUSTOM renderer (fence / code_block) are left
    // alone — replacing them with renderToken would destroy the <pre><code> block (and trap
    // any following math inside a broken <code>, which auto-render then skips).
    function inject(tokens, idx, options, env, self) {
      var t = tokens[idx];
      if (t.map && t.map.length) {
        t.attrJoin("class", "source-line");
        t.attrSet("data-source-line", String(t.map[0] + 1));
      }
      return self.renderToken(tokens, idx, options, env, self);
    }
    ["paragraph_open", "heading_open", "list_item_open", "table_open", "blockquote_open"].forEach(function (rule) {
      inst.renderer.rules[rule] = inject;
    });
    if (FEAT.emoji && typeof window.markdownitEmoji !== "undefined") {
      var emoji = window.markdownitEmoji.full || window.markdownitEmoji;
      try {
        inst.use(emoji);
      } catch (e) {}
    }
    return inst;
  }

  // ---- asciidoctor setup ---------------------------------------------------
  var adoc = null;
  function buildAsciidoc() {
    if (typeof Asciidoctor === "undefined") return null;
    try {
      return Asciidoctor();
    } catch (e) {
      return null;
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
  function render(text) {
    if (CFG.kind === "markdown") {
      if (!md) md = buildMarkdown();
      content.innerHTML = md ? md.render(text) : escapeHtml(text);
    } else if (CFG.kind === "asciidoc") {
      if (!adoc) adoc = buildAsciidoc();
      content.innerHTML = adoc ? adoc.convert(text, { sourcemap: true, attributes: { showtitle: true } }) : escapeHtml(text);
    } else if (CFG.kind === "svg") {
      content.innerHTML = text;
      return; // svg has no code/math/mermaid passes
    } else {
      return; // html: the page renders itself
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
        if (pathMatches(msg.path)) render(msg.content);
      } else if (msg.type === "scroll") {
        if (pathMatches(msg.path)) scrollToLine(msg.line, msg.total);
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
    if (CFG.kind !== "html") render(initialText());
    connect();
    // Reconnect poll: if the socket dropped, try again (onopen reloads the page).
    setInterval(function () {
      if (!socket || socket.readyState === WebSocket.CLOSED) connect();
    }, 1000);
  });
})();
