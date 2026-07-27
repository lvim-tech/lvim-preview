// lvim-preview: the pdf.js worker, with the upsert shim applied first.
//
// A worker is its own realm: nothing the page patched reaches it. And a STATIC import would not help
// either — it is hoisted above the shim — so the real bundle is pulled in dynamically, after.
import "./upsert-shim.mjs";
await import("./pdf.worker.min.mjs");
