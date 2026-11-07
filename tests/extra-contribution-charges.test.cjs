const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const read = p => fs.readFileSync(path.join(__dirname,"..",p),"utf8");
const sql = read("supabase/migrations/20261107140000_atomic_extra_contribution_charges.sql");
const postgres = read("tests/extra-contribution-charges-postgres.sql");

test("Extra charge writes are one service-role-only PostgreSQL transaction", () => {
  assert.match(sql,/RETURNS jsonb/i);
  assert.match(sql,/SET search_path TO ''/i);
  assert.match(sql,/pg_advisory_xact_lock/);
  assert.match(sql,/vbgramg_contribution_exemptions/);
  assert.match(sql,/vbgramg_periods/);
  assert.match(sql,/status,'409'/);
  assert.match(sql,/INSERT INTO public\.vbgramg_charge_ledger/);
  assert.match(sql,/INSERT INTO public\.vbgramg_contribution_extras/);
  assert.match(sql,/ON CONFLICT \(job_card_number,period_id\) DO UPDATE/);
  assert.match(sql,/GET DIAGNOSTICS v_rows=ROW_COUNT/);
  assert.match(sql,/REVOKE ALL ON FUNCTION[\s\S]+FROM PUBLIC/);
  assert.match(sql,/FROM anon,authenticated/);
  assert.match(sql,/TO service_role/);
  assert.doesNotMatch(sql,/SECURITY DEFINER/i);
});

test("Extra charge regression fixture covers insert, update and rejection paths", () => {
  assert.match(postgres,/MZ-EXTRA/);
  assert.match(postgres,/MZ-EXEMPT/);
  assert.match(postgres,/MZ-CLOSED/);
  assert.match(postgres,/MZ-SUPPRESS/);
  assert.match(postgres,/atomic extra contribution charge tests passed/);
});
