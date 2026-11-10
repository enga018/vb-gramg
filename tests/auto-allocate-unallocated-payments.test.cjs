const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const migration = fs.readFileSync(
  path.join(__dirname, "../supabase/migrations/20261107200000_auto_allocate_unallocated_payments_on_new_charge.sql"),
  "utf8"
);

const paymentMigration = fs.readFileSync(
  path.join(__dirname, "../supabase/migrations/20261108150000_auto_allocate_on_new_payment.sql"),
  "utf8"
);

const postgresTest = fs.readFileSync(
  path.join(__dirname, "auto-allocate-unallocated-payments-postgres.sql"),
  "utf8"
);

test("new eligible charges trigger automatic FIFO allocation", () => {
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.vbgramg_auto_allocate_unallocated_payments/);
  assert.match(migration, /AFTER INSERT\s+ON public\.vbgramg_charge_ledger/);
  assert.match(migration, /EXECUTE FUNCTION public\.vbgramg_auto_allocate_after_charge_change/);
});


test("new non-voided payments immediately invoke the shared FIFO allocator", () => {
  assert.match(paymentMigration, /CREATE OR REPLACE FUNCTION public\.vbgramg_auto_allocate_after_payment_insert/);
  assert.match(paymentMigration, /AFTER INSERT[\s\S]*?ON public\.vbgramg_charge_ledger/);
  assert.match(paymentMigration, /NEW\.entry_type <> 'payment'/);
  assert.match(paymentMigration, /vbgramg_auto_allocate_unallocated_payments\(NEW\.job_card_number\)/);
  assert.match(paymentMigration, /SECURITY DEFINER/);
  assert.match(paymentMigration, /REVOKE ALL ON FUNCTION public\.vbgramg_auto_allocate_after_payment_insert\(\)/);
});

test("isolated PostgreSQL tests cover new-payment FIFO and retained excess credit", () => {
  assert.match(postgresTest, /20261108150000_auto_allocate_on_new_payment/);
  assert.match(postgresTest, /MZ-NEW-PAYMENT/);
  assert.match(postgresTest, /MZ-NEW-PAYMENT-SHORT/);
  assert.match(postgresTest, /New-payment FIFO failed/);
});

test("allocation uses oldest periods and oldest available payments first", () => {
  assert.match(migration, /ORDER BY\s+COALESCE\(p\.contribution_month, p\.period_date\) ASC NULLS LAST,\s+p\.created_at ASC/);
  assert.match(migration, /ORDER BY payment\.entry_date ASC NULLS LAST, payment\.created_at ASC, payment\.id ASC/);
  assert.match(migration, /LEAST\(v_payment_available, v_period_due\)/);
});

test("available payment balance excludes existing allocations and reconciled refunds", () => {
  assert.match(migration, /FROM public\.vbgramg_payment_allocations a\s+WHERE a\.transaction_id = v_payment\.id/);
  assert.match(migration, /FROM public\.vbgramg_payment_refund_reconciliations r\s+WHERE r\.payment_id = v_payment\.id/);
});

test("deferred, voided, legacy Return, and exempted cards are excluded", () => {
  assert.match(migration, /vbgramg_contribution_exemptions/);
  assert.match(migration, /COALESCE\(NEW\.is_deferred, false\)/);
  assert.match(migration, /COALESCE\(NEW\.is_voided, false\)/);
  assert.match(migration, /btrim\(COALESCE\(NEW\.note, ''\)\) = 'Return'/);
  assert.match(migration, /AFTER INSERT\s+ON public\.vbgramg_charge_ledger/);
});

test("FTO snapshot acquires the household lock before invoking the existing RPC", () => {
  assert.match(migration, /ALTER FUNCTION public\.vbgramg_apply_fto_snapshot\(jsonb\)\s+RENAME TO vbgramg_apply_fto_snapshot_unlocked/);
  assert.match(migration, /vbgramg-contribution:' \|\| v_card\.job_card_number[\s\S]*?vbgramg_apply_fto_snapshot_unlocked\(p_plan\)/);
});

test("manual replacement locks periods before payment rows", () => {
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.vbgramg_replace_payment_allocations/);
  assert.match(migration, /FROM public\.vbgramg_payment_allocations a[\s\S]*?WHERE a\.transaction_id = p_transaction_id[\s\S]*?ORDER BY x\.period_id[\s\S]*?FOR UPDATE/);
});

test("automatic allocations retain the original payment and write an audit entry", () => {
  assert.match(migration, /INSERT INTO public\.vbgramg_payment_allocations/);
  assert.match(migration, /ON CONFLICT \(transaction_id, period_id\) DO UPDATE/);
  assert.match(migration, /INSERT INTO public\.vbgramg_ledger_audit/);
  assert.match(migration, /'automatic_fifo_allocation'/);
  assert.doesNotMatch(migration, /UPDATE public\.vbgramg_charge_ledger\s+SET amount/);
});

test("isolated PostgreSQL test covers overpayment, FIFO, refunds, deferred and exempt cases", () => {
  assert.match(postgresTest, /Core example/);
  assert.match(postgresTest, /Older payment/);
  assert.match(postgresTest, /Refund-adjusted available balance/);
  assert.match(postgresTest, /restoring one does not/);
  assert.match(postgresTest, /MZ-EXEMPT/);
});


const workflow = fs.readFileSync(
  path.join(__dirname, "../.github/workflows/test-ledger-calculations.yml"),
  "utf8"
);

test("GitHub Actions runs the automatic allocation, waiver, and voided-payment PostgreSQL integration suites", () => {
  assert.match(workflow, /Run automatic unallocated payment FIFO PostgreSQL tests[\\s\\S]*?tests\\/auto-allocate-unallocated-payments-postgres\\.sql/);
  assert.match(workflow, /Run new period-linked waiver PostgreSQL tests[\\s\\S]*?tests\\/new-waiver-period-allocation-postgres\\.sql/);
  assert.match(workflow, /Run voided payment safeguard PostgreSQL tests[\\s\\S]*?tests\\/voided-payment-allocation-safeguards-postgres\\.sql/);
});
