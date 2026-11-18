-- Disposable PostgreSQL integration test for charge-level allocation schema.
-- Run only in a fresh local/CI database:
--   psql -v ON_ERROR_STOP=1 -f tests/charge-level-payment-allocations-postgres.sql

DO $roles$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $roles$;

CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_card_number text NOT NULL,
  person_name text NOT NULL,
  entry_type text NOT NULL,
  amount numeric(12,2) NOT NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  is_deferred boolean NOT NULL DEFAULT false,
  is_voided boolean NOT NULL DEFAULT false
);
CREATE TABLE public.vbgramg_contribution_exemptions (
  job_card_number text PRIMARY KEY,
  note text
);
CREATE TABLE public.vbgramg_payment_refund_reconciliations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL,
  refund_id uuid NOT NULL,
  job_card_number text NOT NULL,
  amount numeric(12,2) NOT NULL
);

\ir ../supabase/migrations/20261108090000_create_charge_level_payment_allocations.sql
\ir ../supabase/migrations/20261119110000_allow_source_specific_charge_allocations.sql

DO $$
DECLARE
  p1 uuid; p2 uuid; p3 uuid; p4 uuid;
  c1 uuid; c2 uuid; c3 uuid; c4 uuid; c5 uuid; c6 uuid;
  v_count integer;
  v_total numeric(12,2);
BEGIN
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','payment',500) RETURNING id INTO p1;
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','charge',300) RETURNING id INTO c1;
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','charge',200) RETURNING id INTO c2;

  -- one payment can fund two charges
  INSERT INTO public.vbgramg_charge_payment_allocations(payment_id,charge_id,amount)
  VALUES (p1,c1,300),(p1,c2,200);

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','payment',100) RETURNING id INTO p2;
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','charge',100) RETURNING id INTO c3;

  -- two payments can fund one charge
  INSERT INTO public.vbgramg_charge_payment_allocations(payment_id,charge_id,amount)
  VALUES (p2,c3,50);
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','payment',50) RETURNING id INTO p3;
  INSERT INTO public.vbgramg_charge_payment_allocations(payment_id,charge_id,amount)
  VALUES (p3,c3,50);
  SELECT count(*) INTO v_count FROM public.vbgramg_charge_payment_allocations
  WHERE charge_id=c3;
  IF v_count<>2 THEN RAISE EXCEPTION 'Expected two payment-to-charge rows'; END IF;

  -- Different sources may coexist for the same payment/charge pair.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','payment',100) RETURNING id INTO p4;
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','charge',100) RETURNING id INTO c6;
  INSERT INTO public.vbgramg_charge_payment_allocations
    (payment_id,charge_id,amount,allocation_source)
  VALUES (p4,c6,30,'manual'),(p4,c6,20,'fifo_auto');

  SELECT count(*),sum(amount) INTO v_count,v_total
  FROM public.vbgramg_charge_payment_allocations
  WHERE payment_id=p4 AND charge_id=c6;
  IF v_count<>2 OR v_total<>50 THEN
    RAISE EXCEPTION 'Expected separate manual and fifo_auto rows totalling 50';
  END IF;

  -- A duplicate row for the same source is rejected.
  BEGIN
    INSERT INTO public.vbgramg_charge_payment_allocations
      (payment_id,charge_id,amount,allocation_source)
    VALUES (p4,c6,1,'manual');
    RAISE EXCEPTION 'duplicate same-source allocation unexpectedly succeeded';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;

  -- Aggregate payment capacity is still enforced across different sources.
  BEGIN
    INSERT INTO public.vbgramg_charge_payment_allocations
      (payment_id,charge_id,amount,allocation_source)
    VALUES (p4,c6,51,'historical_evidence');
    RAISE EXCEPTION 'cross-source payment over-allocation unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM = 'cross-source payment over-allocation unexpectedly succeeded' THEN RAISE; END IF;
  END;

  -- cross-job-card allocation is rejected
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-TWO','Household Two','charge',50) RETURNING id INTO c4;
  BEGIN
    INSERT INTO public.vbgramg_charge_payment_allocations(payment_id,charge_id,amount)
    VALUES (p2,c4,10);
    RAISE EXCEPTION 'cross-job-card allocation is rejected: insert unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'cross-job-card allocation is rejected:%' THEN RAISE; END IF;
  END;

  -- deferred charge is rejected
  UPDATE public.vbgramg_charge_ledger SET is_deferred=true WHERE id=c1;
  BEGIN
    INSERT INTO public.vbgramg_charge_payment_allocations(payment_id,charge_id,amount)
    VALUES (p2,c1,1);
    RAISE EXCEPTION 'deferred charge is rejected: insert unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'deferred charge is rejected:%' THEN RAISE; END IF;
  END;

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount)
  VALUES ('JC-ONE','Household One','charge',25) RETURNING id INTO c5;

  -- payment over-allocation is rejected
  BEGIN
    INSERT INTO public.vbgramg_charge_payment_allocations(payment_id,charge_id,amount)
    VALUES (p1,c5,1);
    RAISE EXCEPTION 'payment over-allocation is rejected: insert unexpectedly succeeded';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'payment over-allocation is rejected:%' THEN RAISE; END IF;
  END;

  -- Original period-level allocation table is not part of this migration.
  IF to_regclass('public.vbgramg_payment_allocations') IS NOT NULL THEN
    RAISE EXCEPTION 'Legacy period-level allocation table should not be created or changed by this isolated fixture';
  END IF;
END $$;

SELECT 'charge-level allocation source tests passed' AS result;
