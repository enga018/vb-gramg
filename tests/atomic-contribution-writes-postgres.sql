-- Ephemeral PostgreSQL integration tests for the atomic contribution write draft.
-- Run from the repository root with:
-- psql -v ON_ERROR_STOP=1 -f tests/atomic-contribution-writes-postgres.sql

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END
$$;

CREATE TABLE public.vbgramg_contribution_exemptions (
  job_card_number text PRIMARY KEY CHECK (length(btrim(job_card_number)) > 0),
  note text NOT NULL DEFAULT '',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_card_number text NOT NULL,
  person_name text NOT NULL,
  entry_type text NOT NULL CHECK (entry_type IN ('charge','payment','refund','other_charge','charge_waiver')),
  amount numeric NOT NULL CHECK (amount > 0),
  charge_period date CHECK (charge_period IS NULL OR EXTRACT(day FROM charge_period) = 1),
  entry_date date DEFAULT CURRENT_DATE,
  note text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  is_deferred boolean NOT NULL DEFAULT false,
  source_created_at_ms bigint,
  legacy_entry_id text,
  is_voided boolean NOT NULL DEFAULT false,
  CHECK (entry_type <> 'charge' OR charge_period IS NOT NULL),
  CHECK (length(btrim(job_card_number)) > 0),
  CHECK (length(btrim(person_name)) > 0)
);

CREATE TABLE public.vbgramg_ledger_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ledger_entry_id uuid,
  job_card_number text NOT NULL,
  action text NOT NULL,
  actor_user_id uuid,
  actor_email text,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.test_skip_exempt_ledger_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = 'public'
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.vbgramg_contribution_exemptions e
    WHERE btrim(e.job_card_number) = btrim(NEW.job_card_number)
  ) OR (NEW.job_card_number = 'MZ-SKIP-TRIGGER' AND NEW.entry_type = 'payment') THEN
    RETURN NULL;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER test_skip_exempt_ledger_write
BEFORE INSERT OR UPDATE ON public.vbgramg_charge_ledger
FOR EACH ROW EXECUTE FUNCTION public.test_skip_exempt_ledger_write();

CREATE OR REPLACE FUNCTION public.test_fail_audit_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF current_setting('test.fail_audit', true) = 'on' THEN
    RAISE EXCEPTION 'intentional audit failure for rollback test';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER test_fail_audit_insert
BEFORE INSERT ON public.vbgramg_ledger_audit
FOR EACH ROW EXECUTE FUNCTION public.test_fail_audit_insert();

GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT, INSERT ON public.vbgramg_contribution_exemptions TO service_role;
GRANT SELECT, INSERT ON public.vbgramg_charge_ledger TO service_role;
GRANT SELECT, INSERT ON public.vbgramg_ledger_audit TO service_role;

\ir ../supabase/migrations/20261106181317_record_contribution_transaction.sql
\ir ../supabase/migrations/20261107034818_atomic_bulk_bank_payment.sql
CREATE TABLE public.vbgramg_fto_batches (
  id uuid PRIMARY KEY,
  fto_number text UNIQUE NOT NULL,
  contribution_period text NOT NULL,
  ledger_charge_period date NOT NULL,
  village_scope text,
  period_id uuid,
  created_by uuid,
  last_checked_at timestamptz,
  last_source_sha256 text
);

\ir ../supabase/migrations/20261107050000_postgres_fto_charge_calculation.sql

INSERT INTO public.vbgramg_charge_ledger (job_card_number, person_name, entry_type, amount, charge_period, note, is_deferred, is_voided)
VALUES
  ('MZ-CASH', 'Cash Card', 'charge', 100, '2026-11-01', 'Charge', false, false),
  ('MZ-FULL', 'Full Card', 'charge', 100.005, '2026-11-01', 'Charge', false, false),
  ('MZ-WAIVER', 'Waiver Card', 'charge', 100, '2026-11-01', 'Charge', false, false),
  ('MZ-RETURN', 'Return Card', 'payment', 100, NULL, 'Bank', false, false),
  ('MZ-DEFERRED', 'Deferred Card', 'charge', 200, '2026-11-01', 'Deferred', true, false),
  ('MZ-VOIDED', 'Voided Card', 'charge', 1000, '2026-11-01', 'Voided charge', false, true),
  ('MZ-VOIDED', 'Voided Card', 'charge', 50, '2026-11-01', 'Active charge', false, false),
  ('MZ-VOIDED', 'Voided Card', 'payment', 40, NULL, 'Voided payment', false, true),
  ('MZ-LEGACY', 'Legacy Card', 'charge', 80, '2026-11-01', 'Charge', false, false),
  ('MZ-LEGACY', 'Legacy Card', 'charge', 10, '2026-11-01', ' Return ', false, false),
  ('MZ-ROLLBACK', 'Rollback Card', 'charge', 100, '2026-11-01', 'Charge', false, false),
  ('MZ-SKIP-TRIGGER', 'Trigger Skip Card', 'charge', 100, '2026-11-01', 'Charge', false, false),
  ('MZ-BANK-1', 'Bank One', 'charge', 100, '2026-11-01', 'Charge', false, false),
  ('MZ-BANK-2', 'Bank Two', 'charge', 100, '2026-11-01', 'Charge', false, false),
  ('MZ-BANK-ROLLBACK', 'Bank Rollback', 'charge', 100, '2026-11-01', 'Charge', false, false);

INSERT INTO public.vbgramg_charge_ledger (job_card_number, person_name, entry_type, amount, note)
VALUES ('MZ-RETURN', 'Return Card', 'refund', 20, 'Earlier return');

INSERT INTO public.vbgramg_contribution_exemptions (job_card_number, note)
VALUES ('MZ-EXEMPT', 'Test exemption');

SET ROLE service_role;

DO $$
DECLARE
  fto_calc jsonb;
BEGIN
  fto_calc := public.vbgramg_calculate_fto_charges(
    '[{"row_index":0,"credit_amount":600,"status":"processed"},{"row_index":1,"credit_amount":600,"status":"blank"},{"row_index":2,"credit_amount":600,"status":"rejected"},{"row_index":3,"credit_amount":1,"status":"processed"}]'::jsonb,
    300, 100
  );
  IF (fto_calc->0->>'calculated_charge')::numeric <> 200
     OR (fto_calc->1->>'calculated_charge')::numeric <> 200
     OR (fto_calc->2->>'calculated_charge')::numeric <> 0
     OR (fto_calc->3->>'calculated_charge')::numeric <> 0.33 THEN
    RAISE EXCEPTION 'FTO charge calculation or two-decimal rounding failed: %', fto_calc;
  END IF;

  fto_calc := public.vbgramg_calculate_fto_charges(
    '[{"row_index":0,"credit_amount":600,"status":"processed"}]'::jsonb, 300, 80
  );
  IF (fto_calc->0->>'calculated_charge')::numeric <> 160 THEN
    RAISE EXCEPTION 'Admin-supplied 80 multiplier was not applied: %', fto_calc;
  END IF;

  BEGIN
    PERFORM public.vbgramg_calculate_fto_charges(
      '[{"row_index":0,"credit_amount":600,"status":"processed"}]'::jsonb, 0, 100
    );
    RAISE EXCEPTION 'Zero divisor should have been rejected';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'Zero divisor should have been rejected' THEN RAISE; END IF;
  END;
END
$;

DO $$
DECLARE
  r jsonb;
  before_count integer;
  after_count integer;
  audit_before integer;
  audit_after integer;
BEGIN
  -- Bulk bank payment success preserves the response and audit contract.
  r := public.vbgramg_record_bulk_bank_payment(
    '[{"job_card_number":"MZ-BANK-1","amount":50},{"job_card_number":"MZ-BANK-2","amount":25}]'::jsonb,
    '2026-11-06', gen_random_uuid(), ' TESTER@EXAMPLE.INVALID '
  );
  IF NOT (r->>'ok')::boolean OR (r->>'count')::integer <> 2
     OR (r->>'total_amount')::numeric <> 75 OR r->>'method' <> 'Bank'
     OR jsonb_array_length(r->'entries') <> 2 THEN
    RAISE EXCEPTION 'Bulk bank payment response contract failed: %', r;
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.vbgramg_charge_ledger
    WHERE job_card_number IN ('MZ-BANK-1','MZ-BANK-2')
      AND entry_type='payment'
      AND (note <> 'Bank' OR entry_date <> '2026-11-06')
  ) THEN
    RAISE EXCEPTION 'Bulk bank payment ledger values were not preserved.';
  END IF;
  IF (SELECT count(*) FROM public.vbgramg_ledger_audit
      WHERE job_card_number IN ('MZ-BANK-1','MZ-BANK-2')
        AND action='bulk-bank-payment' AND actor_email='tester@example.invalid') <> 2 THEN
    RAISE EXCEPTION 'Bulk bank payment audit rows were not recorded correctly.';
  END IF;

  -- Invalid or exempt rows must reject the entire batch before any write.
  r := public.vbgramg_record_bulk_bank_payment(
    '[{"job_card_number":"MZ-BANK-1","amount":10},{"job_card_number":"MZ-BANK-1","amount":20}]'::jsonb,
    '2026-11-06', gen_random_uuid(), 'tester@example.invalid'
  );
  IF (r->>'ok')::boolean OR (r->>'status')::integer <> 400 THEN
    RAISE EXCEPTION 'Duplicate job cards were not rejected: %', r;
  END IF;

  r := public.vbgramg_record_bulk_bank_payment(
    '[{"job_card_number":"MZ-BANK-ROLLBACK","amount":10},{"job_card_number":"MZ-EXEMPT","amount":20}]'::jsonb,
    '2026-11-06', gen_random_uuid(), 'tester@example.invalid'
  );
  IF (r->>'ok')::boolean OR (r->>'status')::integer <> 409 THEN
    RAISE EXCEPTION 'Exempt card did not reject the full batch: %', r;
  END IF;
  IF EXISTS (SELECT 1 FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-BANK-ROLLBACK' AND entry_type='payment') THEN
    RAISE EXCEPTION 'Batch wrote a payment before validating an exempt card.';
  END IF;

  -- A trigger-suppressed insert and an audit failure both roll back the whole batch.
  BEGIN
    PERFORM public.vbgramg_record_bulk_bank_payment(
      '[{"job_card_number":"MZ-BANK-ROLLBACK","amount":10},{"job_card_number":"MZ-SKIP-TRIGGER","amount":20}]'::jsonb,
      '2026-11-06', gen_random_uuid(), 'tester@example.invalid'
    );
    RAISE EXCEPTION 'Expected trigger-suppressed payment failure did not occur';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'Expected trigger-suppressed payment failure did not occur' THEN RAISE; END IF;
  END;
  IF EXISTS (SELECT 1 FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-BANK-ROLLBACK' AND entry_type='payment') THEN
    RAISE EXCEPTION 'Trigger-suppressed row did not roll back the entire batch.';
  END IF;

  PERFORM set_config('test.fail_audit','on',true);
  BEGIN
    PERFORM public.vbgramg_record_bulk_bank_payment(
      '[{"job_card_number":"MZ-BANK-ROLLBACK","amount":10}]'::jsonb,
      '2026-11-06', gen_random_uuid(), 'tester@example.invalid'
    );
    RAISE EXCEPTION 'Expected bulk audit failure did not occur';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'Expected bulk audit failure did not occur' THEN RAISE; END IF;
  END;
  PERFORM set_config('test.fail_audit','off',true);
  IF EXISTS (SELECT 1 FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-BANK-ROLLBACK' AND entry_type='payment') THEN
    RAISE EXCEPTION 'Bulk ledger insert was not rolled back after audit failure.';
  END IF;

  SELECT count(*) INTO audit_before FROM public.vbgramg_ledger_audit WHERE job_card_number='MZ-CASH';
  r := public.vbgramg_record_contribution_transaction('MZ-CASH','cash_payment',150,'2026-11-06','Cash',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->'entry'->>'amount')::numeric <> 150 OR (r->>'balance_after')::numeric <> -50 THEN
    RAISE EXCEPTION 'Cash overpayment behaviour failed: %', r;
  END IF;
  SELECT count(*) INTO audit_after FROM public.vbgramg_ledger_audit WHERE job_card_number='MZ-CASH';
  IF audit_after <> audit_before THEN RAISE EXCEPTION 'Cash payment unexpectedly created an audit row'; END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-FULL','pay_in_full',NULL,'2026-11-06','Pay in full',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->'entry'->>'amount')::numeric <> 100.01 THEN
    RAISE EXCEPTION 'Pay-in-full rounding failed: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-WAIVER','waiver',30,'2026-11-06','Waiver',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->>'balance_after')::numeric <> 70 THEN
    RAISE EXCEPTION 'Waiver calculation failed: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-WAIVER','waiver',1,'2026-11-06','   ',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR r->'entry'->>'note' <> '' THEN
    RAISE EXCEPTION 'Blank waiver note was not preserved: %', r;
  END IF;
  IF r->'entry' ? 'is_voided' THEN
    RAISE EXCEPTION 'RPC response exposed fields outside the legacy ledger projection: %', r->'entry';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.vbgramg_ledger_audit a
    WHERE a.ledger_entry_id = (r->'entry'->>'id')::uuid
      AND a.action = 'waiver'
      AND a.before_data = '{"balance":70}'::jsonb
      AND a.after_data->>'note' = ''
      AND NOT (a.after_data ? 'is_voided')
  ) THEN
    RAISE EXCEPTION 'Waiver audit record did not preserve the legacy payload shape.';
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-RETURN','return',25,'2026-11-06','Return',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->>'balance_before')::numeric <> -80 OR (r->>'balance_after')::numeric <> -55 THEN
    RAISE EXCEPTION 'Return eligibility without a charge row failed: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-VOIDED','pay_in_full',NULL,'2026-11-06','Pay in full',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->'entry'->>'amount')::numeric <> 50 THEN
    RAISE EXCEPTION 'Voided-row exclusion failed: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-LEGACY','pay_in_full',NULL,'2026-11-06','Pay in full',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->'entry'->>'amount')::numeric <> 90 THEN
    RAISE EXCEPTION 'Legacy Return classification failed: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-DEFERRED','pay_in_full',NULL,'2026-11-06','Pay in full',gen_random_uuid(),'tester@example.invalid');
  IF (r->>'ok')::boolean OR (r->>'status')::integer <> 400 THEN
    RAISE EXCEPTION 'Deferred-only balance should reject pay-in-full: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-EXEMPT','cash_payment',10,'2026-11-06','Cash',gen_random_uuid(),'tester@example.invalid');
  IF (r->>'ok')::boolean OR (r->>'status')::integer <> 409 THEN
    RAISE EXCEPTION 'Exempt card was not explicitly rejected: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-SKIP-TRIGGER','cash_payment',10,'2026-11-06','Cash',gen_random_uuid(),'tester@example.invalid');
  IF (r->>'ok')::boolean OR (r->>'status')::integer <> 409 THEN
    RAISE EXCEPTION 'Trigger-suppressed insert was incorrectly reported as successful: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-WAIVER','waiver',1000,'2026-11-06','Waiver',gen_random_uuid(),'tester@example.invalid');
  IF (r->>'ok')::boolean OR (r->>'status')::integer <> 400 THEN
    RAISE EXCEPTION 'Over-limit waiver was not rejected: %', r;
  END IF;

  SELECT count(*) INTO before_count FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-ROLLBACK';
  PERFORM set_config('test.fail_audit','on',true);
  BEGIN
    PERFORM public.vbgramg_record_contribution_transaction('MZ-ROLLBACK','waiver',10,'2026-11-06','Waiver',gen_random_uuid(),'tester@example.invalid');
    RAISE EXCEPTION 'Expected audit failure did not occur';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'Expected audit failure did not occur' THEN RAISE; END IF;
  END;
  PERFORM set_config('test.fail_audit','off',true);
  SELECT count(*) INTO after_count FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-ROLLBACK';
  IF after_count <> before_count THEN
    RAISE EXCEPTION 'Ledger insert was not rolled back after audit failure';
  END IF;
END;
$$;

RESET ROLE;

DO $$
BEGIN
  IF has_function_privilege('anon', 'public.vbgramg_record_bulk_bank_payment(jsonb,date,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon unexpectedly has bulk bank payment execute permission';
  END IF;
  IF has_function_privilege('authenticated', 'public.vbgramg_record_bulk_bank_payment(jsonb,date,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated unexpectedly has bulk bank payment execute permission';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.vbgramg_record_bulk_bank_payment(jsonb,date,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role is missing bulk bank payment execute permission';
  END IF;
  IF has_function_privilege('anon', 'public.vbgramg_record_contribution_transaction(text,text,numeric,date,text,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'anon unexpectedly has execute permission';
  END IF;
  IF has_function_privilege('authenticated', 'public.vbgramg_record_contribution_transaction(text,text,numeric,date,text,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'authenticated unexpectedly has execute permission';
  END IF;
  IF NOT has_function_privilege('service_role', 'public.vbgramg_record_contribution_transaction(text,text,numeric,date,text,uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'service_role is missing execute permission';
  END IF;
END;
$$;

SELECT 'atomic contribution PostgreSQL tests passed' AS result;
