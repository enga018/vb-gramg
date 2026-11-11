const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const read = p => fs.readFileSync(path.join(__dirname,"..",p),"utf8");

const migration = read("supabase/migrations/20261111190000_atomic_manual_contribution_charge_batches.sql");
const edge = read("supabase/functions/vbgramg-contribution-data/index.ts");
const page = read("contribution.html");
const postgres = read("tests/manual-contribution-charges-postgres.sql");

test("Manual charge batch RPC is admin-service-only and validates the complete batch", () => {
  assert.match(migration,/CREATE OR REPLACE FUNCTION public\.vbgramg_save_manual_contribution_charges/);
  assert.match(migration,/SECURITY INVOKER/);
  assert.match(migration,/SET search_path TO ''/);
  assert.match(migration,/jsonb_array_length\(p_entries\)<1 OR pg_catalog\.jsonb_array_length\(p_entries\)>500/);
  assert.match(migration,/vbgramg_contribution_exemptions/);
  assert.match(migration,/vbgramg_periods/);
  assert.match(migration,/MANUAL CHARGE:/);
  assert.match(migration,/vbgramg_contribution_extras/);
  assert.match(migration,/vbgramg_mis_contribution_lookup/);
  assert.match(migration,/vbgramg_mis_contribution_lookup/);
  assert.match(migration,/vbgramg_ledger_audit/);
  assert.match(migration,/EXCEPTION WHEN OTHERS[\s\S]*?All changes were rolled back/);
  assert.match(migration,/REVOKE ALL ON FUNCTION[\s\S]+FROM PUBLIC/);
  assert.match(migration,/FROM anon,authenticated/);
  assert.match(migration,/TO service_role/);
  assert.doesNotMatch(migration,/SECURITY DEFINER/i);
});

test("Edge action is restricted to administrators and validates dates, amounts and duplicates", () => {
  const start = edge.indexOf('if(action==="save-manual-contribution-charges")');
  const end = edge.indexOf('if(action==="save-contribution-extra")',start);
  assert.ok(start >= 0 && end > start);
  const action = edge.slice(start,end);
  assert.match(action,/approved\.role!=="admin"/);
  assert.match(action,/rows\.length>500/);
  assert.match(action,/new Set<string>\(\)/);
  assert.match(action,/Number\.isFinite\(amount\)/);
  assert.match(action,/\^\\d\{4\}-\\d\{2\}-\\d\{2\}\$/);
  assert.match(action,/validIsoDate/);
  assert.match(action,/vbgramg_save_manual_contribution_charges/);
  assert.match(edge,/manual_contribution_extra_charge/);
});

test("Contribution page exposes individual, same-amount bulk and per-card amount entry", () => {
  assert.match(page,/id="manualChargeBtn"/);
  assert.match(page,/function showManualChargeForm\(\)/);
  assert.match(page,/Single job card/);
  assert.match(page,/Bulk job cards/);
  assert.match(page,/Same amount for every job card/);
  assert.match(page,/Different amount per job card/);
  assert.match(page,/Preview charges/);
  assert.match(page,/save-manual-contribution-charges/);
  assert.match(page,/Manual extra charge added/);
  assert.match(page,/periods=Array\.isArray\(data\.periods\)\?data\.periods:\[\]/);
});

test("PostgreSQL fixture exercises batch success, rollback, duplicate and permission paths", () => {
  assert.match(postgres,/MZ-REG-ONE/);
  assert.match(postgres,/MZ-MIS-ONLY/);
  assert.match(postgres,/manual_contribution_extra_charge/);
  assert.match(postgres,/MZ-EXTRA-ONE/);
  assert.match(postgres,/MZ-ROLLBACK/);
  assert.match(postgres,/MZ-EXEMPT/);
  assert.match(postgres,/MZ-CLOSED/);
  assert.match(postgres,/manual contribution charge batch tests passed/);
});
