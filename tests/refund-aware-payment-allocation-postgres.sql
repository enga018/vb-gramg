-- Regression test for refund-aware direct/manual payment allocation guard.
-- Run against a disposable PostgreSQL database only:
--   createdb vbgramg_refund_guard_test
--   PGDATABASE=vbgramg_refund_guard_test psql -v ON_ERROR_STOP=1 -f tests/refund-aware-payment-allocation-postgres.sql
--
-- Reuse the isolated production-like schema and existing allocator/waiver tests,
-- then apply the new guard migration and exercise the direct allocation path.
\ir auto-allocate-unallocated-payments-postgres.sql
\ir ../supabase/migrations/20261108190000_period_linked_new_waivers.sql
\ir ../supabase/migrations/20261114190000_enforce_refund_aware_payment_allocations.sql

DO $refund_aware_allocation_guard$
DECLARE
  v_payment_id uuid;
  v_refund_id uuid;
  v_allocated numeric(12,2);
BEGIN
  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number, person_name, entry_type, amount, entry_date, note)
  VALUES
    ('MZ-REFUND-GUARD-TRIGGER', 'Refund Guard Test', 'payment',
     1000, '2026-11-14', 'Test payment')
  RETURNING id INTO v_payment_id;

  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number, person_name, entry_type, amount, entry_date, note)
  VALUES
    ('MZ-REFUND-GUARD-TRIGGER', 'Refund Guard Test', 'refund',
     200, '2026-11-14', 'Test refund')
  RETURNING id INTO v_refund_id;

  INSERT INTO public.vbgramg_payment_refund_reconciliations
    (payment_id, refund_id, job_card_number, amount, note)
  VALUES
    (v_payment_id, v_refund_id, 'MZ-REFUND-GUARD-TRIGGER',
     200, 'Refund guard regression');

  INSERT INTO public.vbgramg_charge_ledger
    (job_card_number, person_name, entry_type, amount,
     charge_period, period_id, entry_date, note)
  VALUES
    ('MZ-REFUND-GUARD-TRIGGER', 'Refund Guard Test', 'charge',
     1000, '2026-11-01',
     '00000000-0000-0000-0000-000000000001',
     '2026-11-14', 'Test charge');

  SELECT COALESCE(sum(amount), 0)
    INTO v_allocated
  FROM public.vbgramg_payment_allocations
  WHERE transaction_id = v_payment_id;

  IF v_allocated <> 800 THEN
    RAISE EXCEPTION
      'Expected automatic allocation of 800 after 200 refund, received %',
      v_allocated;
  END IF;

  -- The period still has 200 due, so this extra cent is rejected specifically
  -- by the payment-level ceiling (800 allocated + 200 refunded = 1000).
  BEGIN
    INSERT INTO public.vbgramg_payment_allocations
      (transaction_id, period_id, job_card_number, amount,
       allocation_source, confidence)
    VALUES
      (v_payment_id,
       '00000000-0000-0000-0000-000000000001',
       'MZ-REFUND-GUARD-TRIGGER', 0.01, 'manual', 'confirmed');

    RAISE EXCEPTION
      'FAIL: allocation beyond refunded payment capacity was accepted';
  EXCEPTION
    WHEN SQLSTATE '23514' THEN
      NULL;
  END;

  IF (SELECT COALESCE(sum(amount), 0)
      FROM public.vbgramg_payment_allocations
      WHERE transaction_id = v_payment_id) <> 800 THEN
    RAISE EXCEPTION 'Rejected over-allocation changed the payment allocations';
  END IF;
END
$refund_aware_allocation_guard$;

SELECT 'refund-aware payment allocation guard test passed' AS result;
