/* Shared Contribution charge classification helpers. Pure functions only. */
(function () {
  "use strict";

  function isExtraChargeEntry(entry) {
    return Boolean(entry &&
      entry.entry_type === "charge" &&
      /^FTO EXTRA:/i.test(String(entry.note || "")));
  }

  window.VBGRAMGCharges = Object.freeze({ isExtraChargeEntry });
})();
