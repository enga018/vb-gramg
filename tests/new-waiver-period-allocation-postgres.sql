\ir auto-allocate-unallocated-payments-postgres.sql
\ir ../supabase/migrations/20261108190000_period_linked_new_waivers.sql

-- New waivers are allocated FIFO against the unpaid remainder after payments.
DO $new_waiver_tests$
DECLARE
  v_p1 numeric(12,2);
  v_p2 numeric(12,2);
  v_payment_allocated numeric(12,2);
  v_due numeric(12,2);
  v_waiver_id uuid;
  v_before_count integer;
BEGIN
  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES
    ('MZ-WAIVER-FIFO','Waiver Household','charge',500,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','First period'),
    ('MZ-WAIVER-FIFO','Waiver Household','charge',300,'2026-12-01','00000000-0000-0000-0000-000000000002','2026-12-01','Second period');

  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-WAIVER-FIFO','Waiver Household','payment',400,'2026-11-03','Payment');

  SELECT COALESCE(sum(a.amount),0) INTO v_payment_allocated
  FROM public.vbgramg_payment_allocations a
  JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
  WHERE p.job_card_number='MZ-WAIVER-FIFO';
  IF v_payment_allocated <> 400 THEN
    RAISE EXCEPTION 'Payment should be fully allocated before waiver, got %',v_payment_allocated;
  END IF;

  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-WAIVER-FIFO','Waiver Household','charge_waiver',250,'2026-11-04','New partial waiver')
  RETURNING id INTO v_waiver_id;

  SELECT
    COALESCE(sum(amount) FILTER (WHERE period_id='00000000-0000-0000-0000-000000000001'),0),
    COALESCE(sum(amount) FILTER (WHERE period_id='00000000-0000-0000-0000-000000000002'),0)
  INTO v_p1,v_p2
  FROM public.vbgramg_waiver_period_allocations
  WHERE waiver_id=v_waiver_id;

  IF v_p1 <> 100 OR v_p2 <> 150 THEN
    RAISE EXCEPTION 'New waiver FIFO distribution incorrect: first period %, second period %',v_p1,v_p2;
  END IF;

  SELECT COALESCE(sum(a.amount),0) INTO v_payment_allocated
  FROM public.vbgramg_payment_allocations a
  JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
  WHERE p.job_card_number='MZ-WAIVER-FIFO';
  IF v_payment_allocated <> 400 THEN
    RAISE EXCEPTION 'Recording a waiver changed existing payment allocations: %',v_payment_allocated;
  END IF;

  SELECT COALESCE(sum(c.amount),0)
       - COALESCE((SELECT sum(a.amount) FROM public.vbgramg_payment_allocations a WHERE a.job_card_number='MZ-WAIVER-FIFO'),0)
       - COALESCE((SELECT sum(w.amount) FROM public.vbgramg_waiver_period_allocations w WHERE w.job_card_number='MZ-WAIVER-FIFO'),0)
    INTO v_due
  FROM public.vbgramg_charge_ledger c
  WHERE c.job_card_number='MZ-WAIVER-FIFO'
    AND c.entry_type IN ('charge','other_charge','sanitationFee')
    AND NOT c.is_deferred AND NOT c.is_voided;
  IF v_due <> 150 THEN
    RAISE EXCEPTION 'Expected 150 outstanding after new waiver, got %',v_due;
  END IF;

  -- A later payment must allocate only the amount remaining after the waiver.
  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-WAIVER-THEN-PAYMENT','Waiver Household','charge',500,'2027-01-01','00000000-0000-0000-0000-000000000003','2027-01-01','Charge');

  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-WAIVER-THEN-PAYMENT','Waiver Household','charge_waiver',200,'2027-01-02','New waiver');

  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-WAIVER-THEN-PAYMENT','Waiver Household','payment',400,'2027-01-03','Later payment');

  SELECT COALESCE(sum(a.amount),0) INTO v_payment_allocated
  FROM public.vbgramg_payment_allocations a
  JOIN public.vbgramg_charge_ledger p ON p.id=a.transaction_id
  WHERE p.job_card_number='MZ-WAIVER-THEN-PAYMENT';
  IF v_payment_allocated <> 300 THEN
    RAISE EXCEPTION 'Later payment must allocate only 300 after a 200 waiver, got %',v_payment_allocated;
  END IF;

  -- Historical waiver rows are not backfilled. Their unrepresented amount
  -- reduces the available balance for a new waiver without changing the old row.
  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note)
  VALUES ('MZ-WAIVER-LEGACY','Legacy Waiver Household','charge',1000,'2026-11-01','00000000-0000-0000-0000-000000000001','2026-11-01','Charge');

  ALTER TABLE public.vbgramg_charge_ledger DISABLE TRIGGER trg_vbgramg_allocate_new_waiver_fifo;
  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-WAIVER-LEGACY','Legacy Waiver Household','charge_waiver',100,'2026-11-02','Historical waiver');
  ALTER TABLE public.vbgramg_charge_ledger ENABLE TRIGGER trg_vbgramg_allocate_new_waiver_fifo;

  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number,person_name,entry_type,amount,entry_date,note)
  VALUES ('MZ-WAIVER-LEGACY','Legacy Waiver Household','payment',800,'2026-11-03','Payment');

  SELECT count(*) INTO v_before_count
  FROM public.vbgramg_charge_ledger
  WHERE job_card_number='MZ-WAIVER-LEGACY' AND entry_type='charge_waiver';

  BEGIN
    INSERT INTO public.vbgramg_charge_ledger
      (job_card_number,person_name,entry_type,amount,entry_date,note)
    VALUES ('MZ-WAIVER-LEGACY','Legacy Waiver Household','charge_waiver',150,'2026-11-04','Too much new waiver');
    RAISE EXCEPTION 'Expected the new waiver to be rejected because only 100 remains waivable';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    NULL;
  END;

  IF (SELECT count(*) FROM public.vbgramg_charge_ledger
      WHERE job_card_number='MZ-WAIVER-LEGACY' AND entry_type='charge_waiver') <> v_before_count THEN
    RAISE EXCEPTION 'Rejected new waiver was not rolled back';
  END IF;

  -- New period-linked waivers cannot be edited until the revision workflow exists.
  BEGIN
    UPDATE public.vbgramg_charge_ledger
    SET amount=249
    WHERE id=v_waiver_id;
    RAISE EXCEPTION 'Expected an allocated new waiver edit to be rejected';
  EXCEPTION WHEN SQLSTATE '23514' THEN
    NULL;
  END;

  IF NOT EXISTS (
    SELECT 1 FROM public.vbgramg_ledger_audit
    WHERE ledger_entry_id=v_waiver_id AND action='new_waiver_fifo_allocation'
  ) THEN
    RAISE EXCEPTION 'New waiver FIFO allocation audit entry missing';
  END IF;
END
$new_waiver_tests$;

SELECT 'new period-linked waiver tests passed' AS result;
