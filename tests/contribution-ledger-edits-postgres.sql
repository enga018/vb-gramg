-- Ephemeral PostgreSQL tests for atomic generic contribution ledger edits.
-- Run: createdb vbgramg_edits_test && PGDATABASE=vbgramg_edits_test psql -v ON_ERROR_STOP=1 -f tests/contribution-ledger-edits-postgres.sql

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $$;

CREATE TABLE public.vbgramg_periods (
  id uuid PRIMARY KEY,period_name text NOT NULL,period_date date,
  contribution_month date,status text DEFAULT 'open'
);
CREATE TABLE public.vbgramg_contribution_exemptions(job_card_number text PRIMARY KEY,note text);
CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),job_card_number text NOT NULL,person_name text NOT NULL,
  entry_type text NOT NULL,amount numeric NOT NULL CHECK(amount>0),charge_period date,period_id uuid,
  entry_date date,note text,import_id uuid,created_by uuid,created_at timestamptz DEFAULT now(),
  is_deferred boolean DEFAULT false,is_voided boolean DEFAULT false,legacy_entry_id text,source_created_at_ms bigint
);
CREATE TABLE public.vbgramg_payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),transaction_id uuid NOT NULL,period_id uuid NOT NULL,
  job_card_number text NOT NULL,amount numeric NOT NULL,allocation_source text,confidence text,note text,
  created_by uuid,created_at timestamptz DEFAULT now(),updated_at timestamptz DEFAULT now()
);
CREATE TABLE public.vbgramg_payment_refund_reconciliations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),payment_id uuid NOT NULL,refund_id uuid NOT NULL,
  job_card_number text NOT NULL,amount numeric NOT NULL,note text,created_at timestamptz DEFAULT now(),created_by uuid
);
CREATE TABLE public.vbgramg_contribution_extras (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),ledger_entry_id uuid
);
CREATE TABLE public.vbgramg_ledger_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),ledger_entry_id uuid NOT NULL,job_card_number text NOT NULL,
  action text NOT NULL,actor_user_id uuid NOT NULL,actor_email text,before_data jsonb,after_data jsonb,
  created_at timestamptz DEFAULT now()
);

CREATE FUNCTION public.test_validate_refund_reconciliation() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_refund numeric; v_payment numeric; v_total numeric;
BEGIN
  SELECT amount INTO v_refund FROM public.vbgramg_charge_ledger WHERE id=NEW.refund_id;
  SELECT amount INTO v_payment FROM public.vbgramg_charge_ledger WHERE id=NEW.payment_id;
  IF v_refund IS DISTINCT FROM NEW.amount THEN RAISE EXCEPTION 'refund reconciliation amount mismatch'; END IF;
  SELECT COALESCE(sum(a.amount),0)+COALESCE((
    SELECT sum(r.amount) FROM public.vbgramg_payment_refund_reconciliations r
    WHERE r.payment_id=NEW.payment_id AND r.id<>NEW.id
  ),0)+NEW.amount INTO v_total
  FROM public.vbgramg_payment_allocations a WHERE a.transaction_id=NEW.payment_id;
  IF v_total>v_payment THEN RAISE EXCEPTION 'payment reconciliations exceed payment amount'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER test_validate_refund_reconciliation
BEFORE INSERT OR UPDATE ON public.vbgramg_payment_refund_reconciliations
FOR EACH ROW EXECUTE FUNCTION public.test_validate_refund_reconciliation();

CREATE FUNCTION public.test_fail_audit_insert() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.actor_email='audit-fail' THEN RAISE EXCEPTION 'simulated audit failure'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER test_fail_audit_insert BEFORE INSERT ON public.vbgramg_ledger_audit
FOR EACH ROW EXECUTE FUNCTION public.test_fail_audit_insert();

GRANT USAGE ON SCHEMA public TO service_role;
GRANT SELECT,INSERT,UPDATE ON ALL TABLES IN SCHEMA public TO service_role;
\ir ../supabase/migrations/20261107170000_atomic_contribution_ledger_edits.sql

INSERT INTO public.vbgramg_periods VALUES
 ('00000000-0000-0000-0000-000000000001','NOV26','2026-11-01','2026-11-01','open');
INSERT INTO public.vbgramg_charge_ledger(id,job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
VALUES
 ('10000000-0000-0000-0000-000000000001','MZ-EDIT','Edit Household','charge',100,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','FTO: test'),
 ('20000000-0000-0000-0000-000000000001','MZ-EDIT','Edit Household','payment',100,NULL,NULL,'2026-11-02','Bank'),
 ('30000000-0000-0000-0000-000000000001','MZ-EDIT','Edit Household','refund',20,NULL,NULL,'2026-11-03','Refund'),
 ('40000000-0000-0000-0000-000000000001','MZ-LEGACY','Legacy Household','charge',100,'2026-11-01',NULL,'2026-11-01','Legacy charge'),
 ('50000000-0000-0000-0000-000000000001','MZ-EXTRA','Extra Household','charge',30,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','FTO EXTRA: Market Fee'),
 ('60000000-0000-0000-0000-000000000001','MZ-EXEMPT','Exempt Household','charge',100,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Charge'),
 ('70000000-0000-0000-0000-000000000001','MZ-AUDIT','Audit Household','other_charge',50,NULL,NULL,'2026-11-04','Other charge'),
 ('21000000-0000-0000-0000-000000000001','MZ-LEGACY','Legacy Household','payment',10,NULL,NULL,'2026-11-02','Cash');
INSERT INTO public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount)
VALUES
 ('20000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','MZ-EDIT',60),
 ('21000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000001','MZ-LEGACY',10);
INSERT INTO public.vbgramg_payment_refund_reconciliations(payment_id,refund_id,job_card_number,amount,note)
VALUES ('20000000-0000-0000-0000-000000000001','30000000-0000-0000-0000-000000000001','MZ-EDIT',20,'Refund match');
INSERT INTO public.vbgramg_contribution_extras(ledger_entry_id)
VALUES ('50000000-0000-0000-0000-000000000001');
INSERT INTO public.vbgramg_contribution_exemptions VALUES ('MZ-EXEMPT','Exempt');

SET ROLE service_role;
DO $$
DECLARE r jsonb; v_amount numeric; v_rec numeric; v_before jsonb; v_after jsonb; v_actor uuid:=gen_random_uuid();
BEGIN
  -- A payment cannot be reduced below period allocations plus refund reconciliations.
  r:=public.vbgramg_edit_contribution_ledger_entry(
    '20000000-0000-0000-0000-000000000001',79,'2026-11-05','Bank',NULL,false,v_actor,'admin@test');
  IF (r->>'ok')::boolean OR (r->>'status')::int<>409 THEN RAISE EXCEPTION 'Payment reduction below combined reconciliations was not blocked: %',r; END IF;

  -- The exact combined amount is allowed.
  r:=public.vbgramg_edit_contribution_ledger_entry(
    '20000000-0000-0000-0000-000000000001',80,'2026-11-05','Bank',NULL,false,v_actor,'admin@test');
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'Payment edit at reconciled total failed: %',r; END IF;

  -- Refund edit updates its linked reconciliation and audit snapshot together.
  r:=public.vbgramg_edit_contribution_ledger_entry(
    '30000000-0000-0000-0000-000000000001',15,'2026-11-06','Refund revised',NULL,false,v_actor,'admin@test');
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'Refund edit failed: %',r; END IF;
  SELECT amount INTO v_rec FROM public.vbgramg_payment_refund_reconciliations
  WHERE refund_id='30000000-0000-0000-0000-000000000001';
  IF v_rec<>15 THEN RAISE EXCEPTION 'Refund reconciliation was not synchronized: %',v_rec; END IF;
  SELECT before_data,after_data INTO v_before,v_after FROM public.vbgramg_ledger_audit
  WHERE ledger_entry_id='30000000-0000-0000-0000-000000000001' ORDER BY created_at DESC LIMIT 1;
  IF (v_before->'refund_reconciliations'->0->>'amount')::numeric<>20
     OR (v_after->'refund_reconciliations'->0->>'amount')::numeric<>15 THEN
    RAISE EXCEPTION 'Refund reconciliation audit snapshots are incomplete: before %, after %',v_before,v_after;
  END IF;

  -- Period charge cannot be reduced below the saved period allocations.
  r:=public.vbgramg_edit_contribution_ledger_entry(
    '10000000-0000-0000-0000-000000000001',50,'2026-11-07','FTO: test','2026-11-01',false,v_actor,'admin@test');
  IF (r->>'ok')::boolean OR (r->>'status')::int<>409 THEN RAISE EXCEPTION 'Allocated period charge reduction was not blocked: %',r; END IF;
  r:=public.vbgramg_edit_contribution_ledger_entry(
    '10000000-0000-0000-0000-000000000001',70,'2026-11-07','FTO: test','2026-11-01',false,v_actor,'admin@test');
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'Safe period charge edit failed: %',r; END IF;

  -- Legacy charge with an allocation in the same month is ambiguous and cannot be changed.
  r:=public.vbgramg_edit_contribution_ledger_entry(
    '40000000-0000-0000-0000-000000000001',90,'2026-11-07','Legacy charge','2026-11-01',false,v_actor,'admin@test');
  IF (r->>'ok')::boolean OR (r->>'status')::int<>409 THEN RAISE EXCEPTION 'Ambiguous legacy charge edit was not blocked: %',r; END IF;

  -- Dedicated extra-charge rows cannot be changed through the generic edit RPC.
  r:=public.vbgramg_edit_contribution_ledger_entry(
    '50000000-0000-0000-0000-000000000001',35,'2026-11-07','FTO EXTRA: Market Fee','2026-11-01',false,v_actor,'admin@test');
  IF (r->>'ok')::boolean OR (r->>'status')::int<>409 THEN RAISE EXCEPTION 'Generic extra-charge edit was not blocked: %',r; END IF;

  -- Exempt cards cannot be edited.
  r:=public.vbgramg_edit_contribution_ledger_entry(
    '60000000-0000-0000-0000-000000000001',90,'2026-11-07','Charge','2026-11-01',false,v_actor,'admin@test');
  IF (r->>'ok')::boolean OR (r->>'status')::int<>409 THEN RAISE EXCEPTION 'Exempt ledger edit was not blocked: %',r; END IF;

  -- An audit failure rolls back the ledger update in the same transaction.
  BEGIN
    PERFORM public.vbgramg_edit_contribution_ledger_entry(
      '70000000-0000-0000-0000-000000000001',45,'2026-11-07','Other charge',NULL,false,v_actor,'audit-fail');
    RAISE EXCEPTION 'Expected audit insert to fail';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM='Expected audit insert to fail' THEN RAISE; END IF;
  END;
  SELECT amount INTO v_amount FROM public.vbgramg_charge_ledger
  WHERE id='70000000-0000-0000-0000-000000000001';
  IF v_amount<>50 THEN RAISE EXCEPTION 'Ledger update survived an audit failure: %',v_amount; END IF;
END $$;
RESET ROLE;

DO $$ BEGIN
 IF has_function_privilege('anon','public.vbgramg_edit_contribution_ledger_entry(uuid,numeric,date,text,date,boolean,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'anon can execute ledger edit RPC'; END IF;
 IF has_function_privilege('authenticated','public.vbgramg_edit_contribution_ledger_entry(uuid,numeric,date,text,date,boolean,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'authenticated can execute ledger edit RPC'; END IF;
 IF NOT has_function_privilege('service_role','public.vbgramg_edit_contribution_ledger_entry(uuid,numeric,date,text,date,boolean,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'service_role cannot execute ledger edit RPC'; END IF;
END $$;
SELECT 'atomic contribution ledger edit tests passed' AS result;
