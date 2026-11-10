const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

const sourcePath = path.join(__dirname, "../supabase/functions/shared/ledger-calculations.js");
const context = { globalThis: {} };
vm.runInNewContext(fs.readFileSync(sourcePath, "utf8"), context, { filename: sourcePath });
const calculations = context.globalThis.VBGRAMGLedgerCalculations;

test("shared module exposes only the non-financial job-card sorting helper", () => {
  assert.equal(typeof calculations.jobCardSuffixNumber, "function");
  assert.equal(calculations.calculateLedgerState, undefined);
});

test("job-card suffix sorting handles numeric and letter suffixes", () => {
  assert.equal(calculations.jobCardSuffixNumber("JC/145-D"), 145);
  assert.equal(calculations.jobCardSuffixNumber("JC/9"), 9);
  assert.equal(calculations.jobCardSuffixNumber("invalid"), Number.POSITIVE_INFINITY);
});
