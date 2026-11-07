-- Isolated PostgreSQL integration tests for automatic FIFO allocation on new charges.
-- Run against a disposable database only:
--   createdb vbgramg_auto_allocate_test
--   PGDATABASE=vbgramg_auto_allocate_test psql -v ON_ERROR_STOP=1 -f tests/auto-allocate-unallocated-payments-postgres.sql

DO $roles$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $roles$;

CREATE TABLE public.vbgramg_periods (
  id uuid PRIMARY KEY,
  period_name text NOT NULL,
  period_date date,
  contribution_month date,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.vbgramg_contribution_exemptions (
  job_card_number text PRIMARY KEY,
  note text
);
CREATE TABLE public.vbgramg_charge_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  job_card_number text NOT NULL,
  person_name text NOT NULL,
  entry_type text NOT NULL,
  amount numeric(12,2) NOT NULL,
  charge_period date,
  period_id uuid,
  entry_date date,
  note text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  is_deferred boolean NOT NULL DEFAULT false,
  is_voided boolean NOT NULL DEFAULT false
);
CREATE TABLE public.vbgramg_payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  transaction_id uuid NOT NULL,
  period_id uuid NOT NULL,
  job_card_number text NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  allocation_source text NOT NULL DEFAULT 'manual',
  confidence text NOT NULL DEFAULT 'confirmed',
  note text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (transaction_id, period_id)
);
CREATE TABLE public.vbgramg_payment_refund_reconciliations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL,
  refund_id uuid NOT NULL,
  job_card_number text NOT NULL,
  amount numeric(12,2) NOT NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.vbgramg_ledger_audit (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ledger_entry_id uuid,
  job_card_number text NOT NULL,
  action text NOT NULL,
  actor_user_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Minimal equivalent of the production allocation guard for this isolated fixture.
CREATE FUNCTION public.test_validate_payment_allocation()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_payment public.vbgramg_charge_ledger%ROWTYPE;
  v_other_allocations numeric(12,2);
  v_period_card text;
BEGIN
  IF TG_OP = 'UPDATE' AND (
    OLD.job_card_number IS DISTINCT FROM NEW.job_card_number
    OR OLD.period_id IS DISTINCT FROM NEW.period_id
  ) THEN
    RAISE EXCEPTION 'Payment allocation job card and period are immutable';
  END IF;

  -- Match production lock order: period advisory lock before payment row lock.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      'contribution:' || NEW.job_card_number || ':' || NEW.period_id::text, 0
    )
  );

  SELECT * INTO v_payment
  FROM public.vbgramg_charge_ledger
  WHERE id = NEW.transaction_id
  FOR UPDATE;
  IF NOT FOUND OR v_payment.entry_type <> 'payment'
     OR v_payment.job_card_number <> NEW.job_card_number THEN
    RAISE EXCEPTION 'Invalid payment allocation transaction';
  END IF;

  SELECT COALESCE(sum(a.amount),0) INTO v_other_allocations
  FROM public.vbgramg_payment_allocations a
  WHERE a.transaction_id = NEW.transaction_id
    AND a.id IS DISTINCT FROM NEW.id;
  IF v_other_allocations + NEW.amount > v_payment.amount THEN
    RAISE EXCEPTION 'Payment allocation exceeds original payment';
  END IF;

  SELECT c.job_card_number INTO v_period_card
  FROM public.vbgramg_charge_ledger c
  WHERE c.job_card_number = NEW.job_card_number
    AND c.period_id = NEW.period_id
    AND c.entry_type IN ('charge','other_charge','sanitationFee')
    AND NOT c.is_deferred
    AND NOT c.is_voided
    AND NOT (c.entry_type='charge' AND btrim(COALESCE(c.note,''))='Return')
  LIMIT 1;
  IF v_period_card IS NULL THEN
    RAISE EXCEPTION 'No eligible charge for allocation period';
  END IF;

  NEW.updated_at := now();
  RETURN NEW;
END $$;
CREATE TRIGGER test_validate_payment_allocation
BEFORE INSERT OR UPDATE ON public.vbgramg_payment_allocations
FOR EACH ROW EXECUTE FUNCTION public.test_validate_payment_allocation();

-- Stand-in for the production FTO snapshot RPC so this fixture can test the
-- migration's lock-order wrapper without loading the full FTO schema.
CREATE FUNCTION public.vbgramg_apply_fto_snapshot(p_plan jsonb)
RETURNS jsonb LANGUAGE sql AS $$ SELECT pg_catalog.jsonb_build_object('committed',true) $$;

\ir ../supabase/migrations/20261107200000_auto_allocate_unallocated_payments_on_new_charge.sql

INSERT INTO public.vbgramg_periods(id,period_name,period_date,contribution_month,created_at) VALUES
 ('00000000-0000-0000-0000-000000000001','NOV26','2026-11-01','2026-11-01','2026-10-01'),
 ('00000000-0000-0000-0000-000000000002','DEC26','2026-12-01','2026-12-01','2026-11-01'),
 ('00000000-0000-0000-0000-000000000003','JAN27','2027-01-01','2027-01-01','2026-12-01');

DO $$
DECLARE
  v_alloc numeric(12,2);
  v_unallocated numeric(12,2);
  v_count integer;
BEGIN
  -- Core example: a 500 payment covers a 400 charge; the remaining 100 is
  -- allocated automatically when a later 150 charge is added.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-EXAMPLE','Example Household','charge',400,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Base charge');
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-EXAMPLE','Example Household','payment',500,'2026-11-02','Bank');
  INSERT INTO public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount)
  SELECT p.id,'00000000-0000-0000-0000-000000000001','MZ-EXAMPLE',400
  FROM public.vbgramg_charge_ledger p
  WHERE p.job_card_number='MZ-EXAMPLE' AND p.entry_type='payment';

  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-EXAMPLE','Example Household','charge',150,'2026-12-01','00000000-0000-0000-0000-000000000002','2026-12-01','Next period charge');

  SELECT a.amount INTO v_alloc
  FROM public.vbgramg_payment_allocations a
  JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
  WHERE p.job_card_number='MZ-EXAMPLE' AND a.period_id='00000000-0000-0000-0000-000000000002';
  SELECT p.amount-COALESCE(sum(a.amount),0) INTO v_unallocated
  FROM public.vbgramg_charge_ledger p
  LEFT JOIN public.vbgramg_payment_allocations a ON a.transaction_id=p.id
  WHERE p.job_card_number='MZ-EXAMPLE' AND p.entry_type='payment'
  GROUP BY p.id;
  IF v_alloc<>100 OR v_unallocated<>0 THEN
    RAISE EXCEPTION 'Core overpayment allocation failed: allocated %, unallocated %',v_alloc,v_unallocated;
  END IF;

  -- Oldest contribution period is settled before a later period.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-PERIOD','Period Household','payment',150,'2026-11-01','Period FIFO payment');
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-PERIOD','Period Household','charge',100,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Older period charge');
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-PERIOD','Period Household','charge',100,'2026-12-01','00000000-0000-0000-0000-000000000002','2026-12-01','Newer period charge');
  IF (SELECT a.amount FROM public.vbgramg_payment_allocations a
      JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
      WHERE p.job_card_number='MZ-PERIOD' AND a.period_id='00000000-0000-0000-0000-000000000001')<>100
     OR (SELECT a.amount FROM public.vbgramg_payment_allocations a
         JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
         WHERE p.job_card_number='MZ-PERIOD' AND a.period_id='00000000-0000-0000-0000-000000000002')<>50 THEN
    RAISE EXCEPTION 'Oldest contribution period was not allocated first';
  END IF;

  -- Oldest available payment is consumed before the newer payment.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES
   ('MZ-FIFO','FIFO Household','payment',80,'2026-11-01','Older payment'),
   ('MZ-FIFO','FIFO Household','payment',70,'2026-11-02','Newer payment');
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-FIFO','FIFO Household','charge',150,'2027-01-01','00000000-0000-0000-0000-000000000003','2027-01-01','FIFO test charge');
  SELECT count(*) INTO v_count
  FROM public.vbgramg_payment_allocations a
  JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
  WHERE p.job_card_number='MZ-FIFO' AND a.period_id='00000000-0000-0000-0000-000000000003';
  IF v_count<>2 OR NOT EXISTS (
    SELECT 1 FROM public.vbgramg_payment_allocations a
    JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
    WHERE p.job_card_number='MZ-FIFO' AND p.note='Older payment' AND a.amount=80
  ) THEN
    RAISE EXCEPTION 'FIFO payment ordering failed';
  END IF;

  -- Reconciled refunds reduce the payment balance available for future charges.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES
   ('MZ-REFUND','Refund Household','payment',200,'2026-11-01','Payment'),
   ('MZ-REFUND','Refund Household','refund',60,'2026-11-02','Refund');
  INSERT INTO public.vbgramg_payment_refund_reconciliations(payment_id,refund_id,job_card_number,amount)
  SELECT p.id,r.id,'MZ-REFUND',60
  FROM public.vbgramg_charge_ledger p
  JOIN public.vbgramg_charge_ledger r ON r.job_card_number=p.job_card_number AND r.entry_type='refund'
  WHERE p.job_card_number='MZ-REFUND' AND p.entry_type='payment';
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-REFUND','Refund Household','charge',200,'2026-12-01','00000000-0000-0000-0000-000000000002','2026-12-01','Refund balance test');
  SELECT a.amount INTO v_alloc
  FROM public.vbgramg_payment_allocations a
  JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
  WHERE p.job_card_number='MZ-REFUND';
  IF v_alloc<>140 THEN
    RAISE EXCEPTION 'Refund-adjusted available balance should allocate 140, got %',v_alloc;
  END IF;

  -- Deferred charges do not trigger allocation, and restoring one does not
  -- automatically allocate the retained payment balance.
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note,is_deferred)
  VALUES ('MZ-DEFER','Deferred Household','charge',50,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Deferred charge',true);
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-DEFER','Deferred Household','payment',50,'2026-11-02','Payment');
  UPDATE public.vbgramg_charge_ledger SET is_deferred=false
  WHERE job_card_number='MZ-DEFER' AND entry_type='charge';
  IF EXISTS (
    SELECT 1 FROM public.vbgramg_payment_allocations a
    JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
    WHERE p.job_card_number='MZ-DEFER'
  ) THEN
    RAISE EXCEPTION 'Deferred charge restoration unexpectedly triggered allocation';
  END IF;

  -- Exempt job cards are excluded.
  INSERT INTO public.vbgramg_contribution_exemptions VALUES ('MZ-EXEMPT','Exempt');
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-EXEMPT','Exempt Household','payment',100,'2026-11-02','Payment');
  INSERT INTO public.vbgramg_charge_ledger(job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-EXEMPT','Exempt Household','charge',100,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Exempt charge');
  IF EXISTS (
    SELECT 1 FROM public.vbgramg_payment_allocations a
    WHERE a.job_card_number='MZ-EXEMPT'
  ) THEN
    RAISE EXCEPTION 'Exempt job card received an automatic allocation';
  END IF;

  IF (SELECT count(*) FROM public.vbgramg_ledger_audit WHERE action='automatic_fifo_allocation') < 4 THEN
    RAISE EXCEPTION 'Automatic allocation audit entries were not written';
  END IF;
END $$;

SELECT 'automatic unallocated payment FIFO tests passed' AS result;
