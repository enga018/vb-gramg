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
  job_card_number text PRIMARY KEY,
  note text NOT NULL DEFAULT ''
);

CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_card_number text NOT NULL,
  person_name text NOT NULL,
  entry_type text NOT NULL,
  amount numeric NOT NULL,
  entry_date date,
  note text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  is_deferred boolean NOT NULL DEFAULT false,
  is_voided boolean NOT NULL DEFAULT false
);

CREATE TABLE public.vbgramg_ledger_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ledger_entry_id uuid NOT NULL,
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

\ir ../docs/architecture/atomic-contribution-writes.sql

INSERT INTO public.vbgramg_charge_ledger (job_card_number, person_name, entry_type, amount, note, is_deferred, is_voided)
VALUES
  ('MZ-CASH', 'Cash Card', 'charge', 100, 'Charge', false, false),
  ('MZ-FULL', 'Full Card', 'charge', 100.005, 'Charge', false, false),
  ('MZ-WAIVER', 'Waiver Card', 'charge', 100, 'Charge', false, false),
  ('MZ-RETURN', 'Return Card', 'payment', 100, 'Bank', false, false),
  ('MZ-DEFERRED', 'Deferred Card', 'charge', 200, 'Deferred', true, false),
  ('MZ-VOIDED', 'Voided Card', 'charge', 1000, 'Voided charge', false, true),
  ('MZ-VOIDED', 'Voided Card', 'charge', 50, 'Active charge', false, false),
  ('MZ-VOIDED', 'Voided Card', 'payment', 40, 'Voided payment', false, true),
  ('MZ-LEGACY', 'Legacy Card', 'charge', 80, 'Charge', false, false),
  ('MZ-LEGACY', 'Legacy Card', 'charge', 10, ' Return ', false, false),
  ('MZ-ROLLBACK', 'Rollback Card', 'charge', 100, 'Charge', false, false),
  ('MZ-SKIP-TRIGGER', 'Trigger Skip Card', 'charge', 100, 'Charge', false, false);

INSERT INTO public.vbgramg_charge_ledger (job_card_number, person_name, entry_type, amount, note)
VALUES ('MZ-RETURN', 'Return Card', 'refund', 20, 'Earlier return');

INSERT INTO public.vbgramg_contribution_exemptions (job_card_number, note)
VALUES ('MZ-EXEMPT', 'Test exemption');

SET ROLE service_role;

DO $$
DECLARE
  r jsonb;
  before_count integer;
  after_count integer;
BEGIN
  r := public.vbgramg_record_contribution_transaction('MZ-CASH','cash_payment',150,'2026-11-06','Cash',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->'entry'->>'amount')::numeric <> 150 OR (r->>'balance_after')::numeric <> -50 THEN
    RAISE EXCEPTION 'Cash overpayment behaviour failed: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-FULL','pay_in_full',NULL,'2026-11-06','Pay in full',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->'entry'->>'amount')::numeric <> 100.01 THEN
    RAISE EXCEPTION 'Pay-in-full rounding failed: %', r;
  END IF;

  r := public.vbgramg_record_contribution_transaction('MZ-WAIVER','waiver',30,'2026-11-06','Waiver',gen_random_uuid(),'tester@example.invalid');
  IF NOT (r->>'ok')::boolean OR (r->>'balance_after')::numeric <> 70 THEN
    RAISE EXCEPTION 'Waiver calculation failed: %', r;
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
    PERFORM public.vbgramg_record_contribution_transaction('MZ-ROLLBACK','cash_payment',10,'2026-11-06','Cash',gen_random_uuid(),'tester@example.invalid');
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
