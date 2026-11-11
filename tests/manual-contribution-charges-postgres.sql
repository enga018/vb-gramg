-- Disposable PostgreSQL integration tests for manual regular/extra charge batches.
-- Run: psql -v ON_ERROR_STOP=1 -f tests/manual-contribution-charges-postgres.sql
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

CREATE TABLE public.vbgramg_periods (
  id uuid PRIMARY KEY, period_name text NOT NULL, period_date date,
  contribution_month date, status text NOT NULL DEFAULT 'open'
);
CREATE TABLE public.vbgramg_contribution_exemptions (job_card_number text PRIMARY KEY,note text);
CREATE TABLE public.vbgramg_contribution_citizens (job_card_number text PRIMARY KEY,person_name text NOT NULL);
CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),job_card_number text NOT NULL,person_name text NOT NULL,
  entry_type text NOT NULL,amount numeric(14,2) NOT NULL,charge_period date,period_id uuid,
  entry_date date,note text,created_by uuid,created_at timestamptz NOT NULL DEFAULT now(),
  source_created_at_ms bigint,legacy_entry_id text,is_deferred boolean NOT NULL DEFAULT false,is_voided boolean NOT NULL DEFAULT false
);
CREATE TABLE public.vbgramg_contribution_extras (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),job_card_number text NOT NULL,person_name text NOT NULL,
  charge_period date NOT NULL,period_id uuid,amount numeric(14,2) NOT NULL,reason text NOT NULL,
  ledger_entry_id uuid REFERENCES public.vbgramg_charge_ledger(id) ON DELETE SET NULL,
  created_by uuid NOT NULL,updated_by uuid NOT NULL,created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),UNIQUE(job_card_number,period_id)
);
CREATE TABLE public.vbgramg_ledger_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),ledger_entry_id uuid,job_card_number text NOT NULL,
  action text NOT NULL,actor_user_id uuid,actor_email text,before_data jsonb,after_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE FUNCTION public.test_suppress_manual_charge() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.job_card_number='MZ-SUPPRESS' THEN RETURN NULL; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER test_suppress_manual_charge BEFORE INSERT ON public.vbgramg_charge_ledger
FOR EACH ROW EXECUTE FUNCTION public.test_suppress_manual_charge();

GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO service_role;
\ir ../supabase/migrations/20261107140000_atomic_extra_contribution_charges.sql
\ir ../supabase/migrations/20261111190000_atomic_manual_contribution_charge_batches.sql

INSERT INTO public.vbgramg_periods VALUES
 ('00000000-0000-0000-0000-000000000001','NOV26','2026-11-01','2026-11-01','open'),
 ('00000000-0000-0000-0000-000000000002','NOV26 (2)','2026-11-01','2026-11-01','closed');
INSERT INTO public.vbgramg_contribution_citizens VALUES
 ('MZ-REG-ONE','Regular One'),('MZ-REG-TWO','Regular Two'),('MZ-REG-OLD','Regular Old'),
 ('MZ-EXTRA-ONE','Extra One'),('MZ-EXTRA-TWO','Extra Two'),('MZ-EXTRA-OLD','Extra Old'),
 ('MZ-ROLLBACK','Rollback One'),('MZ-SUPPRESS','Suppressed'),('MZ-EXEMPT','Exempt'),
 ('MZ-CLOSED','Closed');

INSERT INTO public.vbgramg_contribution_exemptions VALUES ('MZ-EXEMPT','exempt');
INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
VALUES ('MZ-REG-OLD','Regular Old','charge',10,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','MANUAL CHARGE: existing');

INSERT INTO public.vbgramg_contribution_extras(job_card_number,person_name,charge_period,period_id,amount,reason,created_by,updated_by)
VALUES ('MZ-EXTRA-OLD','Extra Old','2026-11-01','00000000-0000-0000-0000-000000000001',5,'Existing extra',gen_random_uuid(),gen_random_uuid());

SET ROLE service_role;
DO $$
DECLARE r jsonb; n integer; actor uuid:=gen_random_uuid();
BEGIN
  r:=public.vbgramg_save_manual_contribution_charges(
    '[{"job_card_number":"MZ-REG-ONE","amount":100,"entry_date":"2026-11-03"},{"job_card_number":"MZ-REG-TWO","amount":150,"entry_date":"2026-11-04"}]'::jsonb,
    'regular','00000000-0000-0000-0000-000000000001','2026-11-01',NULL,'Manual regular batch',actor,'admin@example.test');
  IF NOT COALESCE((r->>'ok')::boolean,false) OR (r->>'count')::int<>2 OR (r->>'total_amount')::numeric<>250 THEN RAISE EXCEPTION 'Regular batch failed: %',r; END IF;

  r:=public.vbgramg_save_manual_contribution_charges(
    '[{"job_card_number":"MZ-EXTRA-ONE","amount":25,"entry_date":"2026-11-05"},{"job_card_number":"MZ-EXTRA-TWO","amount":35,"entry_date":"2026-11-06"}]'::jsonb,
    'extra','00000000-0000-0000-0000-000000000001','2026-11-01',NULL,'Manual extra batch',actor,'admin@example.test');
  IF NOT COALESCE((r->>'ok')::boolean,false) OR (r->>'count')::int<>2 OR (r->>'total_amount')::numeric<>60 THEN RAISE EXCEPTION 'Extra batch failed: %',r; END IF;

  r:=public.vbgramg_save_manual_contribution_charges(
    '[{"job_card_number":"MZ-REG-ONE","amount":20},{"job_card_number":"MZ-REG-OLD","amount":20}]'::jsonb,
    'regular','00000000-0000-0000-0000-000000000001','2026-11-01','2026-11-07','Duplicate regular',actor,'admin@example.test');
  IF COALESCE((r->>'ok')::boolean,false) THEN RAISE EXCEPTION 'Duplicate regular charge was accepted: %',r; END IF;
  SELECT count(*) INTO n FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-REG-ONE';
  IF n<>1 THEN RAISE EXCEPTION 'A rejected duplicate batch partially wrote regular rows'; END IF;

  r:=public.vbgramg_save_manual_contribution_charges(
    '[{"job_card_number":"MZ-EXTRA-ONE","amount":20},{"job_card_number":"MZ-EXTRA-OLD","amount":20}]'::jsonb,
    'extra','00000000-0000-0000-0000-000000000001','2026-11-01','2026-11-07','Duplicate extra',actor,'admin@example.test');
  IF COALESCE((r->>'ok')::boolean,false) THEN RAISE EXCEPTION 'Existing extra charge was overwritten: %',r; END IF;
  SELECT count(*) INTO n FROM public.vbgramg_contribution_extras WHERE job_card_number='MZ-EXTRA-ONE';
  IF n<>1 THEN RAISE EXCEPTION 'A rejected duplicate extra batch partially wrote rows'; END IF;

  r:=public.vbgramg_save_manual_contribution_charges(
    '[{"job_card_number":"MZ-ROLLBACK","amount":20},{"job_card_number":"MZ-SUPPRESS","amount":20}]'::jsonb,
    'regular','00000000-0000-0000-0000-000000000001','2026-11-01','2026-11-07','Rollback test',actor,'admin@example.test');
  IF COALESCE((r->>'ok')::boolean,false) THEN RAISE EXCEPTION 'Suppressed ledger write was reported as success: %',r; END IF;
  SELECT count(*) INTO n FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-ROLLBACK';
  IF n<>0 THEN RAISE EXCEPTION 'Failed batch did not roll back earlier inserts'; END IF;

  r:=public.vbgramg_save_manual_contribution_charges(
    '[{"job_card_number":"MZ-REG-TWO","amount":20},{"job_card_number":"MZ-EXEMPT","amount":20}]'::jsonb,
    'regular','00000000-0000-0000-0000-000000000001','2026-11-01','2026-11-07','Exemption test',actor,'admin@example.test');
  IF COALESCE((r->>'ok')::boolean,false) THEN RAISE EXCEPTION 'Exempt card was accepted: %',r; END IF;
  SELECT count(*) INTO n FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-REG-TWO';
  IF n<>1 THEN RAISE EXCEPTION 'Exempt batch partially wrote a charge'; END IF;

  r:=public.vbgramg_save_manual_contribution_charges(
    '[{"job_card_number":"MZ-CLOSED","amount":20}]'::jsonb,
    'regular','00000000-0000-0000-0000-000000000002','2026-11-01','2026-11-07','Closed round test',actor,'admin@example.test');
  IF COALESCE((r->>'ok')::boolean,false) OR (r->>'status')::int<>409 THEN RAISE EXCEPTION 'Closed period was accepted: %',r; END IF;

  r:=public.vbgramg_save_manual_contribution_charges(
    '[{"job_card_number":"MZ-CLOSED","amount":20,"entry_date":null}]'::jsonb,
    'regular','00000000-0000-0000-0000-000000000001','2026-11-01',NULL,'Missing date test',actor,'admin@example.test');
  IF COALESCE((r->>'ok')::boolean,false) THEN RAISE EXCEPTION 'Missing entry date was accepted: %',r; END IF;
END $$;
RESET ROLE;

DO $$ BEGIN
  IF has_function_privilege('anon','public.vbgramg_save_manual_contribution_charges(jsonb,text,uuid,date,date,text,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'anon can execute manual charge batch RPC'; END IF;
  IF has_function_privilege('authenticated','public.vbgramg_save_manual_contribution_charges(jsonb,text,uuid,date,date,text,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'authenticated can execute manual charge batch RPC'; END IF;
  IF NOT has_function_privilege('service_role','public.vbgramg_save_manual_contribution_charges(jsonb,text,uuid,date,date,text,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'service_role cannot execute manual charge batch RPC'; END IF;
END $$;
SELECT 'manual contribution charge batch tests passed' AS result;
