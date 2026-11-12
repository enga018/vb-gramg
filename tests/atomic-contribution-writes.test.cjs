const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const read = relative => fs.readFileSync(path.join(__dirname, "..", relative), "utf8");
const sql = read("supabase/migrations/20261106181317_record_contribution_transaction.sql");
const cashCapSql = read("supabase/migrations/20261112150000_limit_cash_payment_to_outstanding_balance.sql");
const html = read("contribution.html");
const sqlTest = read("tests/atomic-contribution-writes-postgres.sql");
const bulkSql = read("supabase/migrations/20261107034818_atomic_bulk_bank_payment.sql");
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

test("Record Payment is limited to the outstanding balance in PostgreSQL and the UI", () => {
  assert.ok(cashCapSql.includes("IF v_amount > GREATEST(0, v_balance) + 0.001"));
  assert.ok(cashCapSql.includes("Payment cannot exceed the current outstanding balance."));
  assert.ok(cashCapSql.includes("pg_advisory_xact_lock"));
  assert.ok(html.includes("Number(c.balance)>0.001?'<button class=\"btn\" type=\"button\" id=\"addPaymentBtn\">Record payment"));
  assert.ok(html.includes("max=\"'+Number(c.balance).toFixed(2)+'\""));
  assert.ok(html.includes("amount>Number(c.balance)+0.001"));
  assert.ok(html.includes("isWaiver?Number(c.balance).toFixed(2):10000000"));
  assert.ok(html.includes("isWaiver&&amount>Number(c.balance)+0.001"));
  assert.ok(html.includes("Waiver cannot exceed the current outstanding balance."));
  assert.ok(sqlTest.includes("Cash overpayment was not rejected"));
  assert.ok(sqlTest.includes("Valid partial cash payment failed"));
  assert.ok(sqlTest.includes("Final exact-balance cash payment failed"));
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


test("Bulk bank payments are validated, locked, and written atomically in PostgreSQL", () => {
  assert.match(bulkSql, /RETURNS jsonb/i);
  assert.match(bulkSql, /SET search_path TO ''/i);
  assert.match(bulkSql, /jsonb_array_length\(p_entries\) > 500/);
  assert.match(bulkSql, /pg_advisory_xact_lock/);
  assert.match(bulkSql, /ORDER BY job_card/);
  assert.match(bulkSql, /vbgramg_contribution_exemptions/);
  assert.match(bulkSql, /No payments were recorded/);
  assert.match(bulkSql, /entry_type, amount, entry_date, note, created_by/);
  assert.match(bulkSql, /'payment', v_row\.amount, p_entry_date, 'Bank'/);
  assert.match(bulkSql, /'bulk-bank-payment'/);
  assert.match(bulkSql, /INSERT INTO public\.vbgramg_ledger_audit/);
  assert.match(bulkSql, /REVOKE ALL ON FUNCTION[\s\S]+FROM PUBLIC/);
  assert.match(bulkSql, /FROM anon, authenticated/);
  assert.match(bulkSql, /TO service_role/);
  assert.doesNotMatch(bulkSql, /SECURITY DEFINER/i);
});

test("Bulk bank payment Edge Function delegates writes to the PostgreSQL RPC", () => {
  const start = edge.indexOf('if(action==="bulk-bank-payment"){');
  const end = edge.indexOf('if(action==="set-payment-allocations"', start);
  const block = edge.slice(start, end);
  assert.match(block, /admin\.rpc\("vbgramg_record_bulk_bank_payment"/);
  assert.match(block, /p_entries:normalized/);
  assert.match(block, /p_actor_user_id:authData\.user\.id/);
  assert.match(block, /p_actor_email:email/);
  assert.doesNotMatch(block, /\.from\("vbgramg_charge_ledger"\)/);
  assert.doesNotMatch(block, /\.from\("vbgramg_ledger_audit"\)/);
});

const ftoMigration = read("supabase/migrations/20261107050000_postgres_fto_charge_calculation.sql");
const ftoPage = read("fto-import.html");

test("FTO charge calculation is PostgreSQL-authoritative and preserves admin parameters", () => {
  assert.match(ftoMigration, /round\(\(\(item->>'credit_amount'\)::numeric\/p_divisor\)\*p_multiplier,2\)/i);
  assert.match(ftoMigration, /calculation_divisor numeric/i);
  assert.match(ftoMigration, /calculation_multiplier numeric/i);
  assert.match(ftoMigration, /calculation_divisor = excluded\.calculation_divisor/i);
  assert.match(ftoMigration, /calculation_multiplier = excluded\.calculation_multiplier/i);
  assert.match(ftoMigration, /TO service_role/i);
  assert.match(edge, /admin\.rpc\("vbgramg_calculate_fto_charges"/);
  const syncStart = edge.indexOf('if(action==="sync-fto-batch"){');
  const syncEnd = edge.indexOf('if(action==="sync-fto-status"){', syncStart);
  const syncBlock = edge.slice(syncStart, syncEnd);
  assert.match(syncBlock, /calculatedByIndex\.get\(rowIndex\)/);
  assert.doesNotMatch(syncBlock, /raw\.calculated_charge/);
  assert.match(syncBlock, /calculation_divisor:divisor,calculation_multiplier:multiplier/);
  assert.match(ftoPage, /action:'calculate-fto-charges'/);
  assert.match(ftoPage, /calculatedChargeForRow\(row\)/);
  assert.doesNotMatch(ftoPage, /creditAmount\/divisor/);
  assert.doesNotMatch(ftoPage, /calculated_charge:Number\(/);
});

const ledgerEditSql = read("supabase/migrations/20261107170000_atomic_contribution_ledger_edits.sql");

test("Generic ledger edits run atomically with audit and linked refund reconciliation", () => {
  assert.match(ledgerEditSql, /SECURITY DEFINER/i);
  assert.match(ledgerEditSql, /SET search_path TO ''/i);
  assert.match(ledgerEditSql, /pg_advisory_xact_lock/);
  assert.match(ledgerEditSql, /FOR UPDATE/);
  assert.match(ledgerEditSql, /UPDATE public\.vbgramg_charge_ledger[\s\S]*?RETURNING \* INTO v_updated/);
  assert.match(ledgerEditSql, /UPDATE public\.vbgramg_payment_refund_reconciliations[\s\S]*?SET amount=p_amount/);
  assert.match(ledgerEditSql, /refund_reconciliations',v_refund_reconciliations_before/);
  assert.match(ledgerEditSql, /INSERT INTO public\.vbgramg_ledger_audit/);
  assert.match(ledgerEditSql, /REVOKE ALL ON FUNCTION[\s\S]+FROM PUBLIC/);
  assert.match(ledgerEditSql, /FROM anon,authenticated/);
  assert.match(ledgerEditSql, /TO service_role/);
});

test("Ledger edits protect payment allocations and period charge ceilings", () => {
  assert.match(ledgerEditSql, /sum\(a\.amount\)[\s\S]*?WHERE a\.transaction_id=v_old\.id/);
  assert.match(ledgerEditSql, /sum\(r\.amount\)[\s\S]*?WHERE r\.payment_id=v_old\.id/);
  assert.match(ledgerEditSql, /v_allocated\+v_refunded>p_amount/);
  assert.match(ledgerEditSql, /v_allocated>v_eligible/);
  assert.match(ledgerEditSql, /legacy charge is not linked to a specific contribution round/);
  assert.match(ledgerEditSql, /FTO-imported charges must be reassigned/);
  assert.match(ledgerEditSql, /Edit this extra charge through the Extra Contribution form/);
});

test("Edge Function delegates generic ledger edits to the atomic PostgreSQL RPC", () => {
  const start = edge.indexOf('if(action==="edit-ledger-entry"){');
  const end = edge.indexOf('if(action==="add-waiver"', start);
  const block = edge.slice(start, end);
  assert.match(block, /admin\.rpc\("vbgramg_edit_contribution_ledger_entry"/);
  assert.match(block, /p_actor_user_id:authData\.user\.id/);
  assert.match(block, /p_actor_email:email/);
  assert.doesNotMatch(block, /\.from\("vbgramg_charge_ledger"\)/);
  assert.doesNotMatch(block, /\.from\("vbgramg_ledger_audit"\)/);
});

test("Extra contribution history exposes a direct edit action using its dedicated form", () => {
  const page = read("contribution.html");
  assert.match(page, /data-edit-extra=/);
  assert.match(page, /showExtraChargeForm\(extraEditButton\.dataset\.fifoEditExtra\|\|extraEditButton\.dataset\.editExtra\)/);
  assert.match(page, /showExtraChargeForm\(preferredPeriodId\)/);
});

test("Citizen transaction history exposes only the agreed balance-based actions", () => {
  assert.match(html, /id="addPaymentBtn">Record payment/);
  assert.match(html, /id="payFullBtn">Pay in full/);
  assert.match(html, /id="waiveBtn">Waive/);
  assert.match(html, /id="returnBtn">Refund/);
  assert.doesNotMatch(html, /id="extraChargeBtn"/);
  assert.doesNotMatch(html, /Add \/ edit extra amount/);
  assert.doesNotMatch(html, /addEventListener\('click',showExtraChargeForm\)/);
  assert.match(html, /c\.exempt\?'<div class="muted">This job card is exempt from contribution\.<\/div>'/);
  assert.match(html, /Number\(c\.balance\)>0\.001\?/);
  assert.match(html, /Number\(c\.balance\)<-0\.001\?/);
});
