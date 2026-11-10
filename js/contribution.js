/* Contribution-page compatibility facade for shared ledger calculations. */
(function () {
  "use strict";

  const shared = window.VBGRAMGLedgerCalculations;
  if (!shared) {
    throw new Error("Shared VBGRAMG ledger calculations did not load.");
  }

  window.VBGRAMGContribution = Object.freeze({
    jobCardSuffixNumber: shared.jobCardSuffixNumber
  });
})();
