const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const sql = read("docs/architecture/atomic-contribution-writes.sql");
const edge = read("supabase/functions/vbgramg-contribution-data/index.ts");

test("Atomic contribution function is a service-role-only invoker function", () => {
  assert.match(sql, /SECURITY INVOKER/i);
  assert.match(sql, /SET search_path = ''/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION[\s\S]+FROM PUBLIC/i);
  assert.match(sql, /FROM anon, authenticated/i);
  assert.match(sql, /TO service_role/i);
  assert.doesNotMatch(sql, /SECURITY DEFINER/i);
});

test("All supported writes serialize by normalized job card and reject exemptions", () => {
  assert.match(sql, /pg_advisory_xact_lock/);
  assert.match(sql, /vbgramg_contribution_exemptions/);
  assert.match(sql, /This job card is exempted/);
  assert.match(sql, /GET DIAGNOSTICS v_rows = ROW_COUNT/);
  assert.match(sql, /did not accept this transaction/);
});

test("Database balance calculation preserves existing ledger classifications", () => {
  assert.match(sql, /NOT COALESCE\(l\.is_voided, false\)/);
  assert.match(sql, /NOT COALESCE\(l\.is_deferred, false\)/);
  assert.match(sql, /entry_type IN \('charge', 'other_charge', 'sanitationFee'\)/);
  assert.match(sql, /entry_type IN \('refund', 'return'\)/);
  assert.match(sql, /entry_type IN \('charge_waiver', 'forgive'\)/);
  assert.match(sql, /btrim\(COALESCE\(l\.note, ''\)\) = 'Return'/);
  assert.match(sql, /GREATEST\(v_charges - LEAST\(v_charges, v_waived\), 0\) - v_paid \+ v_returns/i);
});

test("Operation-specific limits and validation match the current Edge Function rules", () => {
  assert.match(sql, /p_operation IS NULL OR p_operation NOT IN/);
  assert.match(sql, /IF p_operation = 'cash_payment' THEN[\s\S]*?AND l\.entry_type = 'charge'/);
  assert.match(sql, /ELSE[\s\S]*?WHERE l\.job_card_number = v_job_card[\s\S]*?ORDER BY l\.created_at ASC/);
  assert.match(sql, /p_operation = 'cash_payment' AND p_amount > 10000000/);
  assert.match(sql, /pg_catalog\.round\(v_balance, 2\)/);
  assert.match(sql, /Waiver must be positive and cannot exceed the current outstanding balance/);
  assert.match(sql, /Return amount must be positive and cannot exceed payments less previous returns/);
  assert.doesNotMatch(sql, /p_operation IN \('waiver', 'return'\)[\s\S]{0,160}10000000/);
});

test("Ledger insert and audit insert are in the same database function transaction", () => {
  const insertLedger = sql.indexOf("INSERT INTO public.vbgramg_charge_ledger");
  const insertAudit = sql.indexOf("INSERT INTO public.vbgramg_ledger_audit");
  assert.ok(insertLedger >= 0 && insertAudit > insertLedger);
  assert.match(sql, /RETURNING \* INTO v_entry/);
  assert.match(sql, /action, actor_user_id, actor_email, before_data, after_data/);
});


test("Edge Function delegates the four supported writes to the atomic RPC", () => {
  assert.match(edge, /admin\.rpc\("vbgramg_record_contribution_transaction"/);
  assert.match(edge, /p_actor_user_id:actorUserId/);
  assert.match(edge, /p_actor_email:actorEmail/);

  const cashStart = edge.indexOf('if(action==="add-payment"){');
  const cashEnd = edge.indexOf('if(action==="validate-backup-batch"', cashStart);
  const cashBlock = edge.slice(cashStart, cashEnd);
  assert.match(cashBlock, /"cash_payment"/);
  assert.match(cashBlock, /recordContributionWrite/);
  assert.doesNotMatch(cashBlock, /\.from\("vbgramg_charge_ledger"\)\.insert/);

  const adminStart = edge.indexOf('if(action==="add-waiver"||action==="add-return"||action==="pay-in-full"){');
  const adminEnd = edge.indexOf('if(action==="bulk-bank-payment"', adminStart);
  const adminBlock = edge.slice(adminStart, adminEnd);
  assert.match(adminBlock, /"pay_in_full"/);
  assert.match(adminBlock, /"waiver"/);
  assert.match(adminBlock, /"return"/);
  assert.match(adminBlock, /recordContributionWrite/);
  assert.doesNotMatch(adminBlock, /calculateLedgerState/);
  assert.doesNotMatch(adminBlock, /\.from\("vbgramg_charge_ledger"\)\.insert/);
});
