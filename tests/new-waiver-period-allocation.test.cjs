const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const migration = fs.readFileSync(
  path.join(root, "supabase/migrations/20261108190000_period_linked_new_waivers.sql"),
  "utf8"
);
const postgresTests = fs.readFileSync(
  path.join(root, "tests/new-waiver-period-allocation-postgres.sql"),
  "utf8"
);

test("new waiver allocations are stored by waiver and exact period", () => {
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.vbgramg_waiver_period_allocations/);
  assert.match(migration, /waiver_id uuid NOT NULL REFERENCES public\.vbgramg_charge_ledger\(id\)/);
  assert.match(migration, /period_id uuid NOT NULL REFERENCES public\.vbgramg_periods\(id\)/);
  assert.match(migration, /UNIQUE \(waiver_id, period_id\)/);
});

test("new waiver trigger allocates after automatic payment FIFO and preserves old waivers", () => {
  assert.match(migration, /PERFORM public\.vbgramg_auto_allocate_unallocated_payments\(v_card\)/);
  assert.match(migration, /CREATE TRIGGER trg_vbgramg_allocate_new_waiver_fifo/);
  assert.match(migration, /new_waiver_fifo_allocation/);
  assert.match(migration, /v_legacy_waiver_remaining/);
  assert.match(migration, /Historical waiver entries are not backfilled/);
});

test("payment FIFO and manual allocations subtract period-linked new waivers", () => {
  assert.match(migration, /v_period_due := GREATEST\(v_period_charges - v_period_allocated - v_period_waived, 0\)/);
  assert.match(migration, /Payment allocations cannot exceed the period balance remaining after waivers/);\n  assert.match(migration, /CREATE TRIGGER trg_vbgramg_validate_payment_allocation/);
});

test("unsafe edits to period-linked new waivers are rejected", () => {
  assert.match(migration, /CREATE TRIGGER trg_vbgramg_guard_allocated_waiver_edit/);
  assert.match(migration, /cannot be edited or voided until waiver revision is implemented/);
});

test("isolated PostgreSQL tests cover FIFO, partial allocation, legacy compatibility and rollback", () => {
  assert.match(postgresTests, /MZ-WAIVER-FIFO/);
  assert.match(postgresTests, /MZ-WAIVER-THEN-PAYMENT/);
  assert.match(postgresTests, /MZ-WAIVER-LEGACY/);
  assert.match(postgresTests, /Expected manual allocation beyond the post-waiver balance to be rejected/);
  assert.match(postgresTests, /Expected the new waiver to be rejected/);
});
