-- End-to-end PostgreSQL regression tests for extra-charge amount reductions.
-- Run only against a disposable database:
--   createdb vbgramg_extra_reconcile_test
--   PGDATABASE=vbgramg_extra_reconcile_test psql -v ON_ERROR_STOP=1 -f tests/extra-contribution-reconciliation-postgres.sql

\ir ../tests/extra-contribution-charges-postgres.sql

CREATE TABLE public.vbgramg_payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL,
  period_id uuid NOT NULL,
  job_card_number text NOT NULL,
  amount numeric(14,2) NOT NULL CHECK (amount>0),
  allocation_source text NOT NULL DEFAULT 'manual',
  confidence text NOT NULL DEFAULT 'confirmed',
  note text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(transaction_id,period_id)
);
CREATE TABLE public.vbgramg_waiver_period_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  waiver_id uuid NOT NULL,
  period_id uuid NOT NULL,
  job_card_number text NOT NULL,
  amount numeric(14,2) NOT NULL,
  allocation_source text NOT NULL DEFAULT 'fifo_auto',
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
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
GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA public TO service_role;

\ir ../supabase/migrations/20261109130000_reconcile_extra_contribution_charge_edits.sql

-- Exercise the same ceiling enforced by the production allocation trigger.
CREATE FUNCTION public.test_validate_extra_edit_allocation()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_payment public.vbgramg_charge_ledger%ROWTYPE;
  v_charges numeric(14,2);
  v_waived numeric(14,2);
  v_allocated numeric(14,2);
BEGIN
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('contribution:'||NEW.job_card_number||':'||NEW.period_id::text,0)
  );
  SELECT * INTO v_payment FROM public.vbgramg_charge_ledger
  WHERE id=NEW.transaction_id FOR UPDATE;
  IF NOT FOUND OR v_payment.entry_type<>'payment' THEN
    RAISE EXCEPTION 'Invalid payment transaction';
  END IF;
  SELECT COALESCE(sum(c.amount),0) INTO v_charges
  FROM public.vbgramg_charge_ledger c
  WHERE c.job_card_number=NEW.job_card_number AND c.period_id=NEW.period_id
    AND c.entry_type IN ('charge','other_charge','sanitationFee')
    AND NOT COALESCE(c.is_deferred,false) AND NOT COALESCE(c.is_voided,false)
    AND NOT (c.entry_type='charge' AND btrim(COALESCE(c.note,''))='Return');
  SELECT COALESCE(sum(w.amount),0) INTO v_waived
  FROM public.vbgramg_waiver_period_allocations w
  JOIN public.vbgramg_charge_ledger waiver ON waiver.id=w.waiver_id
  WHERE w.job_card_number=NEW.job_card_number AND w.period_id=NEW.period_id
    AND waiver.entry_type IN ('charge_waiver','forgive') AND NOT COALESCE(waiver.is_voided,false);
  SELECT COALESCE(sum(a.amount),0) INTO v_allocated
  FROM public.vbgramg_payment_allocations a
  WHERE a.job_card_number=NEW.job_card_number AND a.period_id=NEW.period_id
    AND a.id IS DISTINCT FROM NEW.id;
  IF v_allocated+NEW.amount>GREATEST(v_charges-v_waived,0)+0.001 THEN
    RAISE EXCEPTION 'Payment allocations exceed eligible period balance';
  END IF;
  IF (SELECT COALESCE(sum(a.amount),0) FROM public.vbgramg_payment_allocations a
      WHERE a.transaction_id=NEW.transaction_id AND a.id IS DISTINCT FROM NEW.id)+NEW.amount>v_payment.amount THEN
    RAISE EXCEPTION 'Payment allocation exceeds original payment';
  END IF;
  NEW.updated_at:=now();
  RETURN NEW;
END $$;
CREATE TRIGGER test_validate_extra_edit_allocation
BEFORE INSERT OR UPDATE ON public.vbgramg_payment_allocations
FOR EACH ROW EXECUTE FUNCTION public.test_validate_extra_edit_allocation();

INSERT INTO public.vbgramg_contribution_citizens(job_card_number,person_name)
VALUES ('MZ-ALLOC','Allocation Household'),('MZ-NO-EXCESS','No Excess Household'),('MZ-WAIVER','Waiver Household'),('MZ-LEGACY','Legacy Waiver Household');

DO $$
DECLARE
  v_result jsonb;
  v_extra_id uuid;
  v_newest_allocation uuid;
  v_oldest_allocation uuid;
  v_payment_id uuid;
  v_waiver_id uuid;
  v_amount numeric(14,2);
  v_total numeric(14,2);
  v_audit_count integer;
BEGIN
  -- Scenario 1: total eligible charges fall from 300 to 200. Keep the oldest
  -- allocation (100) and reduce the newest allocation (200 -> 100), releasing 100.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-ALLOC','Allocation Household','charge',100,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Base charge');

  v_result:=public.vbgramg_save_contribution_extra(
    'MZ-ALLOC','2026-11-01','00000000-0000-0000-0000-000000000001',200,
    'Extra charge before reduction','2026-11-07',gen_random_uuid());
  IF NOT (v_result->>'ok')::boolean THEN RAISE EXCEPTION 'Could not create test extra: %',v_result; END IF;
  v_extra_id:=(v_result->'extra'->>'id')::uuid;

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-ALLOC','Allocation Household','payment',300,'2026-11-02','Payment for extra test')
  RETURNING id INTO v_payment_id;

  INSERT INTO public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount,created_at)
  VALUES (v_payment_id,'00000000-0000-0000-0000-000000000001','MZ-ALLOC',100,'2026-11-02 08:00:00')
  RETURNING id INTO v_oldest_allocation;
  -- A second payment backs the newer allocation.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-ALLOC','Allocation Household','payment',200,'2026-11-03','Second payment')
  RETURNING id INTO v_payment_id;
  INSERT INTO public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount,created_at)
  VALUES (v_payment_id,'00000000-0000-0000-0000-000000000001','MZ-ALLOC',200,'2026-11-03 08:00:00')
  RETURNING id INTO v_newest_allocation;

  v_result:=public.vbgramg_save_contribution_extra(
    'MZ-ALLOC','2026-11-01','00000000-0000-0000-0000-000000000001',100,
    'Reduced extra charge','2026-11-08',gen_random_uuid());
  IF NOT (v_result->>'ok')::boolean THEN RAISE EXCEPTION 'Extra charge reduction failed: %',v_result; END IF;
  IF (v_result->>'released_allocation_amount')::numeric<>100
     OR (v_result->>'released_allocation_count')::int<>1 THEN
    RAISE EXCEPTION 'Expected exactly 100 released from one allocation: %',v_result;
  END IF;
  SELECT amount INTO v_amount FROM public.vbgramg_payment_allocations WHERE id=v_oldest_allocation;
  IF v_amount<>100 THEN RAISE EXCEPTION 'Oldest allocation was not preserved'; END IF;
  SELECT amount INTO v_amount FROM public.vbgramg_payment_allocations WHERE id=v_newest_allocation;
  IF v_amount<>100 THEN RAISE EXCEPTION 'Newest allocation should be partially reduced to 100, got %',v_amount; END IF;
  SELECT sum(amount) INTO v_total FROM public.vbgramg_payment_allocations
  WHERE job_card_number='MZ-ALLOC' AND period_id='00000000-0000-0000-0000-000000000001';
  IF v_total<>200 THEN RAISE EXCEPTION 'Period allocation total should reconcile to 200, got %',v_total; END IF;
  SELECT count(*) INTO v_audit_count FROM public.vbgramg_ledger_audit
  WHERE job_card_number='MZ-ALLOC'
    AND action IN ('extra_contribution_charge_edit','payment_allocation_released_due_to_extra_charge_edit');
  IF v_audit_count<>2 THEN RAISE EXCEPTION 'Expected charge edit and allocation release audit rows, got %',v_audit_count; END IF;

  -- Scenario 2: a different charge in the same round keeps total eligible charges
  -- above allocated payments. Reducing the extra charge must not release anything.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-NO-EXCESS','No Excess Household','charge',200,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Other charge');
  v_result:=public.vbgramg_save_contribution_extra(
    'MZ-NO-EXCESS','2026-11-01','00000000-0000-0000-0000-000000000001',100,
    'Extra charge','2026-11-07',gen_random_uuid());
  IF NOT (v_result->>'ok')::boolean THEN RAISE EXCEPTION 'Could not create no-excess extra: %',v_result; END IF;

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-NO-EXCESS','No Excess Household','payment',150,'2026-11-02','Payment')
  RETURNING id INTO v_payment_id;
  INSERT INTO public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount)
  VALUES (v_payment_id,'00000000-0000-0000-0000-000000000001','MZ-NO-EXCESS',150);

  v_result:=public.vbgramg_save_contribution_extra(
    'MZ-NO-EXCESS','2026-11-01','00000000-0000-0000-0000-000000000001',50,
    'Reduced but still covered','2026-11-08',gen_random_uuid());
  IF NOT (v_result->>'ok')::boolean OR (v_result->>'released_allocation_amount')::numeric<>0 THEN
    RAISE EXCEPTION 'Other eligible charges should prevent unnecessary release: %',v_result;
  END IF;
  SELECT sum(amount) INTO v_total FROM public.vbgramg_payment_allocations
  WHERE job_card_number='MZ-NO-EXCESS' AND period_id='00000000-0000-0000-0000-000000000001';
  IF v_total<>150 THEN RAISE EXCEPTION 'Allocation changed despite sufficient other charges'; END IF;

  -- Scenario 3: period-linked waivers reduce the payment allocation ceiling.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-WAIVER','Waiver Household','charge',100,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Base charge');
  v_result:=public.vbgramg_save_contribution_extra(
    'MZ-WAIVER','2026-11-01','00000000-0000-0000-0000-000000000001',100,
    'Extra charge before waiver test','2026-11-07',gen_random_uuid());
  IF NOT (v_result->>'ok')::boolean THEN RAISE EXCEPTION 'Could not create waiver test extra: %',v_result; END IF;

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-WAIVER','Waiver Household','charge_waiver',50,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-04','Period waiver')
  RETURNING id INTO v_waiver_id;
  INSERT INTO public.vbgramg_waiver_period_allocations(waiver_id,period_id,job_card_number,amount)
  VALUES (v_waiver_id,'00000000-0000-0000-0000-000000000001','MZ-WAIVER',50);

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-WAIVER','Waiver Household','payment',150,'2026-11-05','Payment after waiver')
  RETURNING id INTO v_payment_id;
  INSERT INTO public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount)
  VALUES (v_payment_id,'00000000-0000-0000-0000-000000000001','MZ-WAIVER',150);

  v_result:=public.vbgramg_save_contribution_extra(
    'MZ-WAIVER','2026-11-01','00000000-0000-0000-0000-000000000001',50,
    'Reduced extra charge after waiver','2026-11-08',gen_random_uuid());
  IF NOT (v_result->>'ok')::boolean OR (v_result->>'released_allocation_amount')::numeric<>50 THEN
    RAISE EXCEPTION 'Waiver-adjusted ceiling should release 50: %',v_result;
  END IF;
  SELECT sum(amount) INTO v_total FROM public.vbgramg_payment_allocations
  WHERE job_card_number='MZ-WAIVER' AND period_id='00000000-0000-0000-0000-000000000001';
  IF v_total<>100 THEN RAISE EXCEPTION 'Waiver-adjusted allocation should be 100, got %',v_total; END IF;

  -- Scenario 4: historical waiver ledger rows have no period-allocation rows.
  -- The older period is fully paid, so its 80 legacy waiver remainder flows FIFO
  -- into November's unpaid balance only. It must not reduce the ceiling for the
  -- 150 already allocated in payments when the edited charge total is also 150.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-LEGACY','Legacy Waiver Household','charge',100,'2026-10-01','00000000-0000-0000-0000-000000000003','2026-10-01','Older period charge');
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-LEGACY','Legacy Waiver Household','payment',100,'2026-10-02','Older period payment')
  RETURNING id INTO v_payment_id;
  INSERT INTO public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount)
  VALUES (v_payment_id,'00000000-0000-0000-0000-000000000003','MZ-LEGACY',100);

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-LEGACY','Legacy Waiver Household','charge_waiver',80,'2026-10-03','Historical unallocated waiver');

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-LEGACY','Legacy Waiver Household','charge',100,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','November base charge');
  v_result:=public.vbgramg_save_contribution_extra(
    'MZ-LEGACY','2026-11-01','00000000-0000-0000-0000-000000000001',100,
    'Extra charge before legacy waiver edit','2026-11-07',gen_random_uuid());
  IF NOT (v_result->>'ok')::boolean THEN RAISE EXCEPTION 'Could not create legacy waiver extra: %',v_result; END IF;

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-LEGACY','Legacy Waiver Household','payment',150,'2026-11-05','November payment')
  RETURNING id INTO v_payment_id;
  INSERT INTO public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount)
  VALUES (v_payment_id,'00000000-0000-0000-0000-000000000001','MZ-LEGACY',150);

  v_result:=public.vbgramg_save_contribution_extra(
    'MZ-LEGACY','2026-11-01','00000000-0000-0000-0000-000000000001',50,
    'Reduced extra charge with historical waiver','2026-11-08',gen_random_uuid());
  IF NOT (v_result->>'ok')::boolean OR (v_result->>'released_allocation_amount')::numeric<>0 THEN
    RAISE EXCEPTION 'Historical waiver must not release already allocated payment: %',v_result;
  END IF;
  SELECT sum(amount) INTO v_total FROM public.vbgramg_payment_allocations
  WHERE job_card_number='MZ-LEGACY' AND period_id='00000000-0000-0000-0000-000000000001';
  IF v_total<>150 THEN RAISE EXCEPTION 'Historical waiver must leave paid allocation at 150, got %',v_total; END IF;
END $;

SELECT 'extra contribution allocation reconciliation tests passed' AS result;
