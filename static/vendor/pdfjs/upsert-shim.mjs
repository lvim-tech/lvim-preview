// lvim-preview: the Map "upsert" methods pdf.js 5.6 requires, for engines that do not have them yet.
//
// pdf.js calls `Map.prototype.getOrInsertComputed` (11 sites in the main bundle, 8 in the worker).
// That is the TC39 upsert proposal, which V8 ships only after Chromium 140 — so on QtWebEngine 6.11,
// on a slightly older Chrome, and on Firefox, the bundle throws
//
//     Uncaught TypeError: this[#x].getOrInsertComputed is not a function
//
// on its first use and the page renders a blank canvas: the placeholder is DOM and appears, the
// document never draws. Vendoring an older pdf.js would trade a real defect for missing features, so
// the missing methods are supplied instead, to the proposal's semantics and only when absent.
//
// Loaded in BOTH contexts: the shell imports it before pdf.min.mjs, and worker-shim.mjs pulls it in
// before the worker bundle — the worker is a separate realm and inherits nothing.
for (const Ctor of [Map, WeakMap]) {
  const proto = Ctor.prototype;
  if (typeof proto.getOrInsert !== "function") {
    Object.defineProperty(proto, "getOrInsert", {
      configurable: true,
      writable: true,
      value: function getOrInsert(key, value) {
        if (this.has(key)) {
          return this.get(key);
        }
        this.set(key, value);
        return value;
      },
    });
  }
  if (typeof proto.getOrInsertComputed !== "function") {
    Object.defineProperty(proto, "getOrInsertComputed", {
      configurable: true,
      writable: true,
      value: function getOrInsertComputed(key, callbackfn) {
        if (this.has(key)) {
          return this.get(key);
        }
        // The proposal computes with the KEY and inserts whatever comes back, including undefined.
        const value = callbackfn(key);
        this.set(key, value);
        return value;
      },
    });
  }
}
