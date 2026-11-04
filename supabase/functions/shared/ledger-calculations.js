/* Shared VBGRAMG ledger calculations.
 * Runtime-neutral JavaScript: loaded as a browser script and imported by Deno.
 * Pure calculations only. Database access and financial authority remain server-side.
 */
(function (root) {
  "use strict";

  function calculateLedgerState(ledger) {
    let charged = 0, paid = 0, returned = 0, waived = 0, deferred = 0;
    const active = [];

    for (const entry of ledger || []) {
      if (!entry || entry.is_voided) continue;

      const amount = Math.max(0, Number(entry.amount) || 0);
      const type = entry.entry_type;

      if (type === "payment") {
        paid += amount;
        continue;
      }

      if (type === "refund" || type === "return" ||
          (type === "charge" && String(entry.note || "").trim() === "Return")) {
        returned += amount;
        continue;
      }

      if (type === "charge_waiver" || type === "forgive") {
        waived += amount;
        continue;
      }

      if (type !== "charge" && type !== "other_charge" && type !== "sanitationFee") continue;

      if (entry.is_deferred) {
        deferred += amount;
        continue;
      }

      charged += amount;
      active.push(amount);
    }

    let credit = Math.min(waived, charged);
    for (let i = 0; i < active.length && credit > 0; i++) {
      const used = Math.min(credit, active[i]);
      active[i] -= used;
      credit -= used;
    }

    return {
      charged,
      paid,
      returned,
      waived,
      deferred,
      balance: active.reduce((sum, amount) => sum + amount, 0) - paid + returned
    };
  }

  function jobCardSuffixNumber(jobCard) {
    // Job card suffixes may include a letter code, e.g. /145-D.
    // The numeric portion is the primary sort key.
    const match = String(jobCard || "").trim().match(/\/\s*(\d+)/);
    if (!match) return Number.POSITIVE_INFINITY;
    const number = Number(match[1]);
    return Number.isFinite(number) ? number : Number.POSITIVE_INFINITY;
  }

  root.VBGRAMGLedgerCalculations = Object.freeze({
    calculateLedgerState,
    jobCardSuffixNumber
  });
})(globalThis);
