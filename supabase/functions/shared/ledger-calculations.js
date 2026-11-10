/* Shared VBGRAMG non-financial helpers.
 * Runtime-neutral JavaScript: loaded as a browser script and imported by Deno.
 * Financial calculations and authority reside in PostgreSQL.
 */
(function (root) {
  "use strict";

  function jobCardSuffixNumber(jobCard) {
    // Job card suffixes may include a letter code, e.g. /145-D.
    // The numeric portion is the primary sort key.
    const match = String(jobCard || "").trim().match(/\/\s*(\d+)/);
    if (!match) return Number.POSITIVE_INFINITY;
    const number = Number(match[1]);
    return Number.isFinite(number) ? number : Number.POSITIVE_INFINITY;
  }

  root.VBGRAMGLedgerCalculations = Object.freeze({
    jobCardSuffixNumber
  });
})(globalThis);
