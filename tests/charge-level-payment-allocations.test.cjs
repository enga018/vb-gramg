const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const migration = fs.readFileSync(
  path.join(__dirname, "../supabase/migrations/20261108090000_create_charge_level_payment_allocations.sql"),
  "utf8"
);
const postgresTest = fs.readFileSync(
  path.join(__dirname, "charge-level-payment-allocations-postgres.sql"),
  "utf8"
);

test("charge-level allocation supports many-to-many payment and charge links", () => {
  assert.match(migration, /payment_id uuid NOT NULL REFERENCES public\.vbgramg_charge_ledger/);
  assert.match(migration, /charge_id uuid NOT NULL REFERENCES public\.vbgramg_charge_ledger/);
  assert.match(migration, /UNIQUE \(payment_id, charge_id\)/);
  assert.match(migration, /amount numeric\(12,2\) NOT NULL CHECK \(amount > 0\)/);
});

test("allocation validation enforces payment, charge, household and availability rules", () => {
  for (const pattern of [
    /v_payment\.entry_type IS DISTINCT FROM 'payment'/,
    /v_charge\.entry_type NOT IN/,
    /v_payment\.job_card_number IS DISTINCT FROM v_charge\.job_card_number/,
    /COALESCE\(v_charge\.is_deferred,false\)/,
    /vbgramg_contribution_exemptions/,
    /v_payment_allocated \+ NEW\.amount \+ v_refunded > v_payment\.amount/,
    /v_charge_allocated \+ NEW\.amount > v_charge\.amount/
  ]) assert.match(migration, pattern);
});

test("legacy period allocation table is not modified or dropped", () => {
  assert.doesNotMatch(migration, /DROP TABLE[^;]*vbgramg_payment_allocations/i);
  assert.doesNotMatch(migration, /DELETE FROM public\.vbgramg_payment_allocations/i);
  assert.match(migration, /Legacy period-level allocations remain unchanged/);
});

test("isolated PostgreSQL integration fixture covers valid and invalid allocations", () => {
  assert.match(postgresTest, /one payment can fund two charges/);
  assert.match(postgresTest, /two payments can fund one charge/);
  assert.match(postgresTest, /cross-job-card allocation is rejected/);
  assert.match(postgresTest, /deferred charge is rejected/);
  assert.match(postgresTest, /payment over-allocation is rejected/);
});
