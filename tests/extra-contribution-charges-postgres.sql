-- Ephemeral PostgreSQL tests for the atomic extra-charge RPC.
-- Run: psql -v ON_ERROR_STOP=1 -f tests/extra-contribution-charges-postgres.sql
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

CREATE TABLE public.vbgramg_periods (
  id uuid PRIMARY KEY, period_name text NOT NULL, period_date date,
  contribution_month date, status text DEFAULT 'open', created_at timestamptz DEFAULT now()
);
CREATE TABLE public.vbgramg_contribution_exemptions (job_card_number text PRIMARY KEY,note text);
CREATE TABLE public.vbgramg_contribution_citizens (job_card_number text PRIMARY KEY,person_name text NOT NULL);
CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),job_card_number text NOT NULL,person_name text NOT NULL,
  entry_type text NOT NULL CHECK(entry_type IN ('charge','payment','refund','other_charge','charge_waiver')),
  amount numeric NOT NULL CHECK(amount>0),charge_period date,period_id uuid,entry_date date,note text,
  created_by uuid,created_at timestamptz DEFAULT now(),is_deferred boolean DEFAULT false,
  source_created_at_ms bigint,legacy_entry_id text,is_voided boolean DEFAULT false
);
CREATE TABLE public.vbgramg_contribution_extras (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),job_card_number text NOT NULL,person_name text NOT NULL,
  charge_period date NOT NULL,period_id uuid,amount numeric NOT NULL,reason text NOT NULL,
  ledger_entry_id uuid REFERENCES public.vbgramg_charge_ledger(id) ON DELETE SET NULL,
  created_by uuid,updated_by uuid,created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now(),
  UNIQUE(job_card_number,period_id)
);
CREATE FUNCTION public.test_suppress_extra_ledger() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF NEW.job_card_number='MZ-SUPPRESS' THEN RETURN NULL; END IF;
 RETURN NEW;
END $$;
CREATE TRIGGER test_suppress_extra_ledger BEFORE INSERT OR UPDATE ON public.vbgramg_charge_ledger
FOR EACH ROW EXECUTE FUNCTION public.test_suppress_extra_ledger();

GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO service_role;
\ir ../supabase/migrations/20261107140000_atomic_extra_contribution_charges.sql

INSERT INTO public.vbgramg_periods (id,period_name,period_date,contribution_month,status) VALUES
 ('00000000-0000-0000-0000-000000000001','NOV26','2026-11-01','2026-11-01','open'),
 ('00000000-0000-0000-0000-000000000002','NOV26(2)','2026-11-01','2026-11-01','closed'),
 ('00000000-0000-0000-0000-000000000003','OCT26','2026-10-01','2026-10-01','open');
INSERT INTO public.vbgramg_contribution_citizens VALUES
 ('MZ-EXTRA','Citizen Name'),('MZ-CLOSED','Closed Name'),('MZ-SUPPRESS','Suppressed Name');
INSERT INTO public.vbgramg_contribution_exemptions VALUES ('MZ-EXEMPT','exempt');
INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,note)
VALUES ('MZ-EXTRA','Existing Name','charge',100,'2026-11-01','Base charge');

SET ROLE service_role;
DO $$
DECLARE r jsonb; old_extra uuid; old_entry uuid; n integer;
BEGIN
 r:=public.vbgramg_save_contribution_extra('MZ-EXTRA','2026-11-01','00000000-0000-0000-0000-000000000001',25,'Reason A','2026-11-07',gen_random_uuid());
 IF NOT (r->>'ok')::boolean OR (r->'entry'->>'amount')::numeric<>25 OR (r->>'updated')::boolean THEN RAISE EXCEPTION 'Insert failed: %',r; END IF;
 old_extra:=(r->'extra'->>'id')::uuid; old_entry:=(r->'entry'->>'id')::uuid;
 r:=public.vbgramg_save_contribution_extra('MZ-EXTRA','2026-11-01','00000000-0000-0000-0000-000000000001',40,'Reason B','2026-11-07',gen_random_uuid());
 IF NOT (r->>'updated')::boolean OR (r->'extra'->>'id')::uuid<>old_extra OR (r->'entry'->>'id')::uuid<>old_entry OR (r->'entry'->>'amount')::numeric<>40 THEN RAISE EXCEPTION 'Update failed: %',r; END IF;
 SELECT count(*) INTO n FROM public.vbgramg_charge_ledger WHERE job_card_number='MZ-EXTRA' AND note LIKE 'FTO EXTRA:%';
 IF n<>1 THEN RAISE EXCEPTION 'Duplicate linked ledger rows after update'; END IF;

 r:=public.vbgramg_save_contribution_extra('MZ-EXEMPT','2026-11-01','00000000-0000-0000-0000-000000000001',10,'Exempt','2026-11-07',gen_random_uuid());
 IF (r->>'ok')::boolean OR (r->>'status')::int<>409 THEN RAISE EXCEPTION 'Exemption not rejected: %',r; END IF;
 r:=public.vbgramg_save_contribution_extra('MZ-CLOSED','2026-11-01','00000000-0000-0000-0000-000000000002',10,'Closed','2026-11-07',gen_random_uuid());
 IF (r->>'ok')::boolean OR (r->>'status')::int<>409 THEN RAISE EXCEPTION 'Closed round not rejected: %',r; END IF;
 r:=public.vbgramg_save_contribution_extra('MZ-EXTRA','2026-10-01','00000000-0000-0000-0000-000000000001',10,'Wrong month','2026-11-07',gen_random_uuid());
 IF (r->>'ok')::boolean OR (r->>'status')::int<>400 THEN RAISE EXCEPTION 'Mismatched month not rejected: %',r; END IF;
 r:=public.vbgramg_save_contribution_extra('MZ-UNKNOWN','2026-11-01','00000000-0000-0000-0000-000000000001',10,'Unknown','2026-11-07',gen_random_uuid());
 IF (r->>'ok')::boolean OR (r->>'status')::int<>404 THEN RAISE EXCEPTION 'Unknown card not rejected: %',r; END IF;

 BEGIN
  PERFORM public.vbgramg_save_contribution_extra('MZ-SUPPRESS','2026-11-01','00000000-0000-0000-0000-000000000001',10,'Suppressed','2026-11-07',gen_random_uuid());
  RAISE EXCEPTION 'Expected suppressed ledger write to fail';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM='Expected suppressed ledger write to fail' THEN RAISE; END IF; END;
 SELECT count(*) INTO n FROM public.vbgramg_contribution_extras WHERE job_card_number='MZ-SUPPRESS';
 IF n<>0 THEN RAISE EXCEPTION 'Extra row committed despite suppressed ledger insert'; END IF;
END $$;
RESET ROLE;

DO $$ BEGIN
 IF has_function_privilege('anon','public.vbgramg_save_contribution_extra(text,date,uuid,numeric,text,date,uuid)','EXECUTE') THEN RAISE EXCEPTION 'anon can execute extra RPC'; END IF;
 IF has_function_privilege('authenticated','public.vbgramg_save_contribution_extra(text,date,uuid,numeric,text,date,uuid)','EXECUTE') THEN RAISE EXCEPTION 'authenticated can execute extra RPC'; END IF;
 IF NOT has_function_privilege('service_role','public.vbgramg_save_contribution_extra(text,date,uuid,numeric,text,date,uuid)','EXECUTE') THEN RAISE EXCEPTION 'service_role cannot execute extra RPC'; END IF;
END $$;
SELECT 'atomic extra contribution charge tests passed' AS result;
