const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const path = require("node:path");

const sourcePath = path.join(__dirname, "../supabase/functions/shared/ledger-calculations.js");
const context = { globalThis: {} };
vm.runInNewContext(fs.readFileSync(sourcePath, "utf8"), context, { filename: sourcePath });
const calculations = context.globalThis.VBGRAMGLedgerCalculations;

test("shared calculation module exposes a stable API", () => {
  assert.equal(typeof calculations.calculateLedgerState, "function");
  assert.equal(typeof calculations.jobCardSuffixNumber, "function");
});

test("all supported charge types contribute to the balance", () => {
  const result = calculations.calculateLedgerState([
    { entry_type: "charge", amount: 100 },
    { entry_type: "other_charge", amount: 25 },
    { entry_type: "sanitationFee", amount: 30 }
  ]);
  assert.equal(result.charged, 155);
  assert.equal(result.balance, 155);
});

test("payments reduce the outstanding balance", () => {
  const result = calculations.calculateLedgerState([
    { entry_type: "charge", amount: 100 },
    { entry_type: "payment", amount: 40 }
  ]);
  assert.equal(result.paid, 40);
  assert.equal(result.balance, 60);
});

test("refunds and legacy returns increase the outstanding balance", () => {
  const refund = calculations.calculateLedgerState([
    { entry_type: "charge", amount: 100 },
    { entry_type: "payment", amount: 100 },
    { entry_type: "refund", amount: 20 }
  ]);
  assert.equal(refund.returned, 20);
  assert.equal(refund.balance, 20);

  const legacy = calculations.calculateLedgerState([
    { entry_type: "charge", amount: 100 },
    { entry_type: "charge", amount: 10, note: "Return" }
  ]);
  assert.equal(legacy.returned, 10);
  assert.equal(legacy.balance, 110);
});

test("waivers are capped at active charges and applied once", () => {
  const result = calculations.calculateLedgerState([
    { entry_type: "charge", amount: 50 },
    { entry_type: "charge_waiver", amount: 80 }
  ]);
  assert.equal(result.waived, 80);
  assert.equal(result.balance, 0);
});

test("legacy forgive entries remain supported", () => {
  const result = calculations.calculateLedgerState([
    { entry_type: "charge", amount: 100 },
    { entry_type: "forgive", amount: 30 }
  ]);
  assert.equal(result.balance, 70);
});

test("deferred charges are reported but excluded from the balance", () => {
  const result = calculations.calculateLedgerState([
    { entry_type: "charge", amount: 100, is_deferred: true }
  ]);
  assert.equal(result.deferred, 100);
  assert.equal(result.charged, 0);
  assert.equal(result.balance, 0);
});

test("voided entries are ignored", () => {
  const result = calculations.calculateLedgerState([
    { entry_type: "charge", amount: 100, is_voided: true },
    { entry_type: "payment", amount: 50, is_voided: true }
  ]);
  assert.equal(result.charged, 0);
  assert.equal(result.paid, 0);
  assert.equal(result.balance, 0);
});

test("negative and invalid amounts are normalized to zero", () => {
  const result = calculations.calculateLedgerState([
    { entry_type: "charge", amount: -10 },
    { entry_type: "other_charge", amount: "not-a-number" },
    { entry_type: "sanitationFee", amount: "12.50" }
  ]);
  assert.equal(result.charged, 12.5);
  assert.equal(result.balance, 12.5);
});

test("job card suffix sorting handles letter suffixes", () => {
  assert.equal(calculations.jobCardSuffixNumber("JC/145-D"), 145);
  assert.equal(calculations.jobCardSuffixNumber("JC/9"), 9);
  assert.equal(calculations.jobCardSuffixNumber("invalid"), Number.POSITIVE_INFINITY);
});
