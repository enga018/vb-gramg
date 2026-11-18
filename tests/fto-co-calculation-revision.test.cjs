const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const edge = read("supabase/functions/vbgramg-contribution-data/index.ts");
const page = read("fto.html");
const migration = read("supabase/migrations/20261118240000_atomic_fto_co_calculation_revision.sql");
const snapshotGuard = read("supabase/migrations/20261118242000_guard_fto_co_revision_preview_snapshot.sql");
const cleanup = read("supabase/migrations/20261118243000_drop_legacy_fto_co_revision_rpc.sql");
const deferredGuard = read("supabase/migrations/20261118244000_exclude_deferred_charges_from_co_revision_allocation_guard.sql");

test("CO revision preview is admin-only and recalculates saved Credit Amount values", () => {
  const start = edge.indexOf('if(action==="preview-fto-co-revision"){');
  const end = edge.indexOf('if(action==="apply-fto-co-revision"){', start);
  assert.notEqual(start, -1);
  assert.notEqual(end, -1);
  const preview = edge.slice(start, end);
  assert.match(preview, /approved\.role!=="admin"/);
  assert.match(preview, /vbgramg_get_fto_revision_snapshot/);
  assert.match(preview, /vbgramg_calculate_fto_charges/);
  assert.match(preview, /credit_amount:tx\.credit_amount/);
  assert.match(preview, /tx\.is_current===true&&tx\.is_in_scope===true/);
  assert.match(preview, /previous_parameters_recorded/);
  assert.match(preview, /expected_last_deferred_recheck_at/);
  assert.match(preview, /FTO changed while its calculation preview was being prepared/);
});

test("CO revision preview fails closed for missing links, exemptions, and unsupported allocations", () => {
  assert.match(edge, /no linked charge or exemption evidence/);
  assert.match(edge, /allocations\/waivers exceeding the revised eligible charges/);
  assert.match(edge, /unlinked legacy waiver/);
  assert.match(edge, /charge-level allocations exceeding its revised FTO charge/);
});

test("CO revision apply delegates to a service-role-only atomic database operation", () => {
  const start = edge.indexOf('if(action==="apply-fto-co-revision"){');
  const end = edge.indexOf('if(action==="list-fto-history"){', start);
  assert.notEqual(start, -1);
  assert.notEqual(end, -1);
  const apply = edge.slice(start, end);
  assert.match(apply, /approved\.role!=="admin"/);
  assert.match(apply, /vbgramg_apply_fto_co_revision/);
  assert.match(apply, /expected_revision_number/);
  assert.match(apply, /p_expected_period_id/);
  assert.match(apply, /p_expected_last_checked_at/);
  assert.match(apply, /p_expected_last_deferred_recheck_at/);
  assert.match(snapshotGuard, /last_deferred_recheck_at is distinct from p_expected_last_deferred_recheck_at/);
  assert.match(cleanup, /drop function if exists public\.vbgramg_apply_fto_co_revision\(uuid,integer,numeric,numeric,text,uuid,text\)/);
  assert.match(migration, /revoke all on function public\.vbgramg_apply_fto_co_revision/);
  assert.match(migration, /grant execute on function public\.vbgramg_apply_fto_co_revision[\s\S]*to service_role/);
});

test("Atomic CO revision preserves allocations and rejects unsupported balances", () => {
  assert.match(migration, /contribution-card:/);
  assert.match(migration, /contribution:' \|\| v_card/);
  assert.match(migration, /allocated \+ v_waived > v_non_fto \+ v_new_card_total/);
  assert.match(migration, /charge_payment_allocations/);
  assert.match(deferredGuard, /coalesce\(fto_charge\.is_deferred,false\) = false/);
  assert.match(migration, /allocations_preserved',true/);
  assert.doesNotMatch(migration, /delete from public\.vbgramg_payment_allocations/i);
  assert.doesNotMatch(migration, /delete from public\.vbgramg_waiver_period_allocations/i);
});

test("Atomic CO revision recalculates transactions, updates linked ledger charges, and stores immutable snapshots", () => {
  assert.match(migration, /round\(\(v_tx\.credit_amount \/ p_divisor\) \* p_multiplier, 2\)/);
  assert.match(migration, /update public\.vbgramg_fto_transactions[\s\S]*set calculated_charge = v_new_charge/);
  assert.match(migration, /update public\.vbgramg_charge_ledger[\s\S]*set amount = v_new_charge/);
  assert.match(migration, /vbgramg_fto_revision_history/);
  assert.match(migration, /before_snapshot,after_snapshot/);
  assert.match(migration, /fto_co_calculation_revised/);
});

test("FTO history UI exposes Change CO Calculation instead of the obsolete Revise action", () => {
  assert.match(page, /Change CO Calculation/);
  assert.match(page, /preview-fto-co-revision/);
  assert.match(page, /apply-fto-co-revision/);
  assert.match(page, /Credit Amount/);
  assert.match(page, /Existing payment allocations are preserved/);
  assert.doesNotMatch(page, /fto-revise-button/);
  assert.doesNotMatch(page, /openFtoImportForRevision/);
});


test("CO revision preview exposes allocation and waiver validation results in the UI", () => {
  assert.match(edge, /validation_summary:\\{job_cards_checked:checkedCards\\.size/);
  assert.match(edge, /payment_and_waiver_allocations:\\{checked:paymentWaiverChecked\\.size,passed:paymentWaiverChecksPassed\\}/);
  assert.match(edge, /charge_level_allocations:\\{checked:chargeAllocationChecked\\.size,passed:chargeAllocationChecksPassed\\}/);
  assert.match(edge, /unlinked_waivers:\\{checked:unlinkedWaiverChecked\\.size,passed:unlinkedWaiverChecksPassed\\}/);
  assert.match(page, /Payment and waiver allocations/);
  assert.match(page, /Direct charge-level allocations/);
  assert.match(page, /Legacy waiver links/);
  assert.match(page, /unique job cards checked across these safeguards/);
});
