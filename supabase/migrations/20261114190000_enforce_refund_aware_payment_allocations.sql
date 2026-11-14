-- Make the database trigger enforce the same refund-aware payment ceiling
-- already used by the automatic allocator and allocation replacement RPC.
--
-- Existing trigger remains attached; CREATE OR REPLACE updates its function body.
CREATE OR REPLACE FUNCTION public.vbgramg_validate_payment_allocation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_payment public.vbgramg_charge_ledger%ROWTYPE;
  v_payment_allocated numeric(14,2) := 0;
  v_payment_refunded numeric(14,2) := 0;
  v_period_allocated numeric(14,2) := 0;
  v_period_charges numeric(14,2) := 0;
  v_period_waived numeric(14,2) := 0;
BEGIN
  IF TG_OP = 'UPDATE' AND (
    OLD.job_card_number IS DISTINCT FROM NEW.job_card_number
    OR OLD.period_id IS DISTINCT FROM NEW.period_id
  ) THEN
    RAISE EXCEPTION 'Payment allocation job card and period are immutable';
  END IF;

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
     OR v_payment.job_card_number IS DISTINCT FROM NEW.job_card_number
     OR COALESCE(v_payment.is_voided, false) THEN
    RAISE EXCEPTION 'Only an active payment belonging to this job card can be allocated';
  END IF;

  SELECT COALESCE(pg_catalog.sum(a.amount), 0)::numeric(14,2)
    INTO v_payment_allocated
  FROM public.vbgramg_payment_allocations a
  WHERE a.transaction_id = NEW.transaction_id
    AND a.id IS DISTINCT FROM NEW.id;

  SELECT COALESCE(pg_catalog.sum(r.amount), 0)::numeric(14,2)
    INTO v_payment_refunded
  FROM public.vbgramg_payment_refund_reconciliations r
  WHERE r.payment_id = NEW.transaction_id;

  IF v_payment_allocated + NEW.amount + v_payment_refunded
       > v_payment.amount + 0.001 THEN
    RAISE EXCEPTION
      'Allocations plus reconciled refunds cannot exceed the original payment amount'
      USING ERRCODE = '23514';
  END IF;

  SELECT COALESCE(pg_catalog.sum(c.amount), 0)::numeric(14,2)
    INTO v_period_charges
  FROM public.vbgramg_charge_ledger c
  WHERE c.job_card_number = NEW.job_card_number
    AND c.period_id = NEW.period_id
    AND c.entry_type IN ('charge', 'other_charge', 'sanitationFee')
    AND COALESCE(c.is_deferred, false) = false
    AND COALESCE(c.is_voided, false) = false
    AND NOT (c.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(c.note, '')) = 'Return');

  SELECT COALESCE(pg_catalog.sum(a.amount), 0)::numeric(14,2)
    INTO v_period_allocated
  FROM public.vbgramg_payment_allocations a
  JOIN public.vbgramg_charge_ledger payment ON payment.id = a.transaction_id
  WHERE a.job_card_number = NEW.job_card_number
    AND a.period_id = NEW.period_id
    AND payment.entry_type = 'payment'
    AND COALESCE(payment.is_voided, false) = false
    AND a.id IS DISTINCT FROM NEW.id;

  SELECT COALESCE(pg_catalog.sum(w.amount), 0)::numeric(14,2)
    INTO v_period_waived
  FROM public.vbgramg_waiver_period_allocations w
  JOIN public.vbgramg_charge_ledger waiver ON waiver.id = w.waiver_id
  WHERE w.job_card_number = NEW.job_card_number
    AND w.period_id = NEW.period_id
    AND waiver.entry_type IN ('charge_waiver', 'forgive')
    AND COALESCE(waiver.is_voided, false) = false;

  IF v_period_allocated + NEW.amount > GREATEST(v_period_charges - v_period_waived, 0) + 0.001 THEN
    RAISE EXCEPTION 'Payment allocations cannot exceed the period balance remaining after waivers'
      USING ERRCODE = '23514';
  END IF;

  IF v_period_charges <= 0 THEN
    RAISE EXCEPTION 'This job card has no eligible charge for the selected period';
  END IF;

  NEW.updated_at := pg_catalog.now();
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.vbgramg_validate_payment_allocation() FROM PUBLIC, anon, authenticated;
