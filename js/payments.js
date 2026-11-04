/* Shared Contribution payment input parsing. No database access or writes. */
(function () {
  "use strict";

  function parseBulkPayments(raw) {
    const rows = [], errors = [], seen = new Set();
    const lines = String(raw || "").split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) continue;
      if (i === 0 && /job.?card/i.test(line) && /amount/i.test(line)) continue;
      const parts = line.split(/\t|,|;/).map(value => value.trim());
      if (parts.length < 2) {
        errors.push("Line " + (i + 1) + ": use Job Card, Amount.");
        continue;
      }
      const jobCard = parts[0];
      const amount = Number(parts[1].replace(/[₹,\s]/g, ""));
      if (!jobCard) {
        errors.push("Line " + (i + 1) + ": job card number is missing.");
        continue;
      }
      if (!Number.isFinite(amount) || amount <= 0 || amount > 10000000) {
        errors.push("Line " + (i + 1) + ": enter a valid positive amount.");
        continue;
      }
      if (seen.has(jobCard)) {
        errors.push("Line " + (i + 1) + ": duplicate job card " + jobCard + ".");
        continue;
      }
      seen.add(jobCard);
      rows.push({ job_card_number: jobCard, amount });
    }
    if (!rows.length && !errors.length) errors.push("Paste at least one job card and amount.");
    if (rows.length > 500) errors.push("A batch can contain at most 500 payments.");
    return { rows, errors };
  }

  window.VBGRAMGPayments = Object.freeze({ parseBulkPayments });
})();
