const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const migration = read("supabase/migrations/20261109130000_reconcile_extra_contribution_charge_edits.sql");

test("Extra charge edits serialize with contribution and period allocation writes", () => {
  assert.match(migration, /pg_advisory_xact_lock[\s\S]*?vbgramg-contribution:/);
  assert.match(migration, /pg_advisory_xact_lock[\s\S]*?contribution:/);
  assert.match(migration, /FROM public\.vbgramg_periods[\s\S]*?FOR UPDATE/);
});

test("Reduced extra charges reconcile the period ceiling after period waivers", () => {
  assert.match(migration, /sum\(c\.amount\)[\s\S]*?entry_type IN \('charge','other_charge','sanitationFee'\)/);
  assert.match(migration, /sum\(w\.amount\)[\s\S]*?vbgramg_waiver_period_allocations/);
  assert.match(migration, /GREATEST\(v_eligible_charges-v_period_waived,0\)/);
  assert.match(migration, /GREATEST\(v_allocated_total-v_eligible_charges,0\)/);
});

test("Allocation releases retain FIFO order and release only the exact excess", () => {
  assert.match(migration, /ORDER BY a\.created_at DESC,a\.id DESC/);
  assert.match(migration, /LEAST\(v_allocation\.amount,v_excess_to_release\)/);
  assert.match(migration, /SET amount=v_remaining_amount/);
  assert.match(migration, /DELETE FROM public\.vbgramg_payment_allocations WHERE id=v_allocation\.id/);
  assert.match(migration, /Could not reconcile the excess period payment allocations/);
});

test("Allocation writes follow period, payment, allocation lock order", () => {
  assert.match(migration, /Lock payment rows before allocation rows/);
  assert.match(migration, /ORDER BY payment\.id[\s\S]*?FOR UPDATE/);
  assert.match(migration, /FOR UPDATE OF a/);
});

test("Every released allocation and edited extra charge receives a before/after audit record", () => {
  assert.match(migration, /payment_allocation_released_due_to_extra_charge_edit/);
  assert.match(migration, /extra_contribution_charge_edit/);
  assert.match(migration, /released_allocations/);
  assert.match(migration, /pg_catalog\.to_jsonb\(v_old\)/);
  assert.match(migration, /pg_catalog\.to_jsonb\(v_extra\)/);
});

test("The extra-charge RPC remains service-role-only and preserves its API signature", () => {
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.vbgramg_save_contribution_extra\(/);
  assert.match(migration, /p_actor_user_id uuid/);
  assert.match(migration, /SET search_path TO ''/);
  assert.match(migration, /REVOKE ALL ON FUNCTION[\s\S]*FROM PUBLIC/);
  assert.match(migration, /FROM anon,authenticated/);
  assert.match(migration, /TO service_role/);
  assert.doesNotMatch(migration, /SECURITY DEFINER/i);
});
