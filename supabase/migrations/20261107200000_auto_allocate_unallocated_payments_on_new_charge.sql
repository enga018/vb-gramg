-- Automatically consume a job card's existing unallocated payments when a new eligible
-- contribution charge is inserted.
-- This is period-aware, FIFO, and leaves payment ledger rows unchanged.

CREATE OR REPLACE FUNCTION public.vbgramg_auto_allocate_unallocated_payments(
  p_job_card_number text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_card text := pg_catalog.btrim(COALESCE(p_job_card_number, ''));
  v_period record;
  v_payment record;
  v_period_charges numeric(14,2);
  v_period_allocated numeric(14,2);
  v_period_due numeric(14,2);
  v_payment_allocated numeric(14,2);
  v_payment_refunded numeric(14,2);
  v_payment_available numeric(14,2);
  v_take numeric(14,2);
  v_allocation_before numeric(14,2);
  v_allocation_after numeric(14,2);
  v_allocation_id uuid;
  v_allocated_total numeric(14,2) := 0;
  v_allocation_count integer := 0;
BEGIN
  IF v_card = '' THEN
    RETURN pg_catalog.jsonb_build_object('allocated_amount', 0, 'allocation_count', 0);
  END IF;

  -- Exempt cards must never receive automatic contribution allocations.
  IF EXISTS (
    SELECT 1
    FROM public.vbgramg_contribution_exemptions e
    WHERE pg_catalog.btrim(e.job_card_number) = v_card
  ) THEN
    RETURN pg_catalog.jsonb_build_object('allocated_amount', 0, 'allocation_count', 0, 'skipped', 'exempt');
  END IF;

  -- Acquire every eligible period lock in UUID order before locking payment
  -- rows. This matches FTO reconciliation and the hardened manual-allocation RPC,
  -- preventing a period/payment lock-order inversion.
  FOR v_period IN
    SELECT p.id
    FROM public.vbgramg_periods p
    WHERE EXISTS (
      SELECT 1
      FROM public.vbgramg_charge_ledger c
      WHERE c.job_card_number = v_card
        AND c.period_id = p.id
        AND c.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND COALESCE(c.is_deferred, false) = false
        AND COALESCE(c.is_voided, false) = false
        AND NOT (c.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(c.note, '')) = 'Return')
    )
    ORDER BY p.id
  LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('contribution:' || v_card || ':' || v_period.id::text, 0)
    );
  END LOOP;

  -- Oldest contribution round first. The period table's creation timestamp
  -- distinguishes multiple rounds in the same contribution month.
  FOR v_period IN
    SELECT p.id
    FROM public.vbgramg_periods p
    WHERE EXISTS (
      SELECT 1
      FROM public.vbgramg_charge_ledger c
      WHERE c.job_card_number = v_card
        AND c.period_id = p.id
        AND c.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND COALESCE(c.is_deferred, false) = false
        AND COALESCE(c.is_voided, false) = false
        AND NOT (c.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(c.note, '')) = 'Return')
    )
    ORDER BY
      COALESCE(p.contribution_month, p.period_date) ASC NULLS LAST,
      p.created_at ASC,
      p.id ASC
  LOOP
    SELECT COALESCE(pg_catalog.sum(c.amount), 0)::numeric(14,2)
      INTO v_period_charges
    FROM public.vbgramg_charge_ledger c
    WHERE c.job_card_number = v_card
      AND c.period_id = v_period.id
      AND c.entry_type IN ('charge', 'other_charge', 'sanitationFee')
      AND COALESCE(c.is_deferred, false) = false
      AND COALESCE(c.is_voided, false) = false
      AND NOT (c.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(c.note, '')) = 'Return');

    SELECT COALESCE(pg_catalog.sum(a.amount), 0)::numeric(14,2)
      INTO v_period_allocated
    FROM public.vbgramg_payment_allocations a
    JOIN public.vbgramg_charge_ledger payment
      ON payment.id = a.transaction_id
    WHERE a.job_card_number = v_card
      AND a.period_id = v_period.id
      AND payment.entry_type = 'payment'
      AND COALESCE(payment.is_voided, false) = false;

    v_period_due := GREATEST(v_period_charges - v_period_allocated, 0);

    IF v_period_due <= 0 THEN
      CONTINUE;
    END IF;

    -- Payments are consumed oldest first. A payment's available balance is
    -- reduced by both existing allocations and its reconciled refunds.
    FOR v_payment IN
      SELECT payment.id, payment.amount, payment.created_by
      FROM public.vbgramg_charge_ledger payment
      WHERE payment.job_card_number = v_card
        AND payment.entry_type = 'payment'
        AND COALESCE(payment.is_voided, false) = false
        AND payment.amount > 0
      ORDER BY payment.entry_date ASC NULLS LAST, payment.created_at ASC, payment.id ASC
      FOR UPDATE
    LOOP
      SELECT
        COALESCE((
          SELECT pg_catalog.sum(a.amount)
          FROM public.vbgramg_payment_allocations a
          WHERE a.transaction_id = v_payment.id
        ), 0)::numeric(14,2),
        COALESCE((
          SELECT pg_catalog.sum(r.amount)
          FROM public.vbgramg_payment_refund_reconciliations r
          WHERE r.payment_id = v_payment.id
        ), 0)::numeric(14,2)
      INTO v_payment_allocated, v_payment_refunded;

      v_payment_available := GREATEST(
        v_payment.amount - v_payment_allocated - v_payment_refunded,
        0
      );
      v_take := LEAST(v_payment_available, v_period_due);

      IF v_take <= 0 THEN
        CONTINUE;
      END IF;

      SELECT a.amount
        INTO v_allocation_before
      FROM public.vbgramg_payment_allocations a
      WHERE a.transaction_id = v_payment.id
        AND a.period_id = v_period.id;

      v_allocation_before := COALESCE(v_allocation_before, 0);

      INSERT INTO public.vbgramg_payment_allocations (
        transaction_id, period_id, job_card_number, amount,
        allocation_source, confidence, note, created_by
      ) VALUES (
        v_payment.id, v_period.id, v_card, v_take,
        'fifo_auto', 'confirmed', 'Automatic FIFO allocation when an eligible charge was added',
        v_payment.created_by
      )
      ON CONFLICT (transaction_id, period_id) DO UPDATE
      SET amount = public.vbgramg_payment_allocations.amount + EXCLUDED.amount,
          updated_at = pg_catalog.now()
      RETURNING id, amount INTO v_allocation_id, v_allocation_after;

      INSERT INTO public.vbgramg_ledger_audit (
        ledger_entry_id, job_card_number, action, actor_user_id,
        before_data, after_data
      ) VALUES (
        v_payment.id,
        v_card,
        'automatic_fifo_allocation',
        NULL,
        pg_catalog.jsonb_build_object(
          'period_id', v_period.id,
          'allocation_amount', v_allocation_before,
          'payment_unallocated_before', v_payment_available
        ),
        pg_catalog.jsonb_build_object(
          'allocation_id', v_allocation_id,
          'period_id', v_period.id,
          'amount_added', v_take,
          'allocation_amount', v_allocation_after,
          'payment_unallocated_after', v_payment_available - v_take
        )
      );

      v_period_due := v_period_due - v_take;
      v_allocated_total := v_allocated_total + v_take;
      v_allocation_count := v_allocation_count + 1;

      EXIT WHEN v_period_due <= 0;
    END LOOP;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'allocated_amount', v_allocated_total,
    'allocation_count', v_allocation_count
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.vbgramg_auto_allocate_after_charge_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.period_id IS NULL
     OR NEW.entry_type NOT IN ('charge', 'other_charge', 'sanitationFee')
     OR COALESCE(NEW.is_deferred, false)
     OR COALESCE(NEW.is_voided, false)
     OR (NEW.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(NEW.note, '')) = 'Return') THEN
    RETURN NEW;
  END IF;

  PERFORM public.vbgramg_auto_allocate_unallocated_payments(NEW.job_card_number);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_vbgramg_auto_allocate_after_charge_change
  ON public.vbgramg_charge_ledger;

CREATE TRIGGER trg_vbgramg_auto_allocate_after_charge_change
AFTER INSERT
ON public.vbgramg_charge_ledger
FOR EACH ROW
EXECUTE FUNCTION public.vbgramg_auto_allocate_after_charge_change();


-- The manual replacement RPC must take the same period-before-payment lock order
-- as the automatic allocator and FTO reconciliation. The earlier implementation
-- locked the payment first and then hit the period lock in the allocation trigger.
CREATE OR REPLACE FUNCTION public.vbgramg_replace_payment_allocations(
  p_transaction_id uuid,
  p_allocations jsonb,
  p_allocation_source text DEFAULT 'manual',
  p_user_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_card text;
  tx public.vbgramg_charge_ledger%ROWTYPE;
  item jsonb;
  period_value uuid;
  amount_value numeric(12,2);
  confidence_value text;
  total numeric(12,2) := 0;
  inserted_count integer := 0;
  seen_periods uuid[] := ARRAY[]::uuid[];
  v_lock record;
  v_refunded numeric(12,2) := 0;
BEGIN
  IF p_transaction_id IS NULL THEN
    RAISE EXCEPTION 'Valid payment transaction required';
  END IF;
  IF p_allocation_source NOT IN ('fifo_auto','manual','historical_evidence','historical_fifo_reviewed') THEN
    RAISE EXCEPTION 'Invalid allocation source';
  END IF;
  IF pg_catalog.jsonb_typeof(p_allocations) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Allocations must be an array';
  END IF;
  IF pg_catalog.jsonb_array_length(p_allocations) > 100 THEN
    RAISE EXCEPTION 'Too many allocation rows';
  END IF;

  -- Read the card identity without taking a row lock. Validate the full payload
  -- before taking advisory locks or modifying any allocation rows.
  SELECT l.job_card_number INTO v_card
  FROM public.vbgramg_charge_ledger l
  WHERE l.id = p_transaction_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Valid payment transaction required';
  END IF;

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_allocations) LOOP
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'Each allocation must be an object';
    END IF;
    BEGIN
      period_value := NULLIF(item->>'period_id','')::uuid;
      amount_value := (item->>'amount')::numeric(12,2);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'Each allocation needs a valid period UUID and amount';
    END;
    IF period_value IS NULL OR amount_value IS NULL OR amount_value <= 0 THEN
      RAISE EXCEPTION 'Each allocation needs a valid period and positive amount';
    END IF;
    IF period_value = ANY(seen_periods) THEN
      RAISE EXCEPTION 'Duplicate period rows are not allowed; combine amounts for the same period';
    END IF;
    seen_periods := pg_catalog.array_append(seen_periods, period_value);
    confidence_value := COALESCE(NULLIF(item->>'confidence',''),'confirmed');
    IF confidence_value NOT IN ('confirmed','probable','review_required') THEN
      RAISE EXCEPTION 'Invalid allocation confidence';
    END IF;
    total := total + amount_value;
  END LOOP;

  -- Lock both existing and requested periods in stable UUID order before locking
  -- the payment row. This also protects replacement/deletion of prior allocations.
  FOR v_lock IN
    SELECT DISTINCT x.period_id
    FROM (
      SELECT a.period_id
      FROM public.vbgramg_payment_allocations a
      WHERE a.transaction_id = p_transaction_id
      UNION ALL
      SELECT (j.value->>'period_id')::uuid
      FROM pg_catalog.jsonb_array_elements(p_allocations) AS j(value)
    ) AS x
    ORDER BY x.period_id
  LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('contribution:' || v_card || ':' || v_lock.period_id::text, 0)
    );
  END LOOP;

  SELECT * INTO tx
  FROM public.vbgramg_charge_ledger
  WHERE id = p_transaction_id
  FOR UPDATE;

  IF NOT FOUND OR tx.entry_type <> 'payment' OR tx.job_card_number IS DISTINCT FROM v_card THEN
    RAISE EXCEPTION 'Valid payment transaction required';
  END IF;

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_allocations) LOOP
    period_value := (item->>'period_id')::uuid;
    IF NOT EXISTS (
      SELECT 1
      FROM public.vbgramg_charge_ledger c
      WHERE c.job_card_number = tx.job_card_number
        AND c.period_id = period_value
        AND c.entry_type IN ('charge','other_charge','sanitationFee')
        AND COALESCE(c.is_deferred,false) = false
        AND COALESCE(c.is_voided,false) = false
        AND NOT (c.entry_type='charge' AND pg_catalog.btrim(COALESCE(c.note,''))='Return')
    ) THEN
      RAISE EXCEPTION 'Selected period has no eligible charge for this job card';
    END IF;
  END LOOP;

  SELECT COALESCE(pg_catalog.sum(r.amount),0)::numeric(12,2)
    INTO v_refunded
  FROM public.vbgramg_payment_refund_reconciliations r
  WHERE r.payment_id = p_transaction_id;

  IF total + v_refunded > tx.amount THEN
    RAISE EXCEPTION 'Allocations plus reconciled refunds exceed the original payment amount';
  END IF;

  DELETE FROM public.vbgramg_payment_allocations
  WHERE transaction_id = p_transaction_id;

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_allocations) LOOP
    INSERT INTO public.vbgramg_payment_allocations(
      transaction_id, period_id, job_card_number, amount,
      allocation_source, confidence, note, created_by
    ) VALUES (
      p_transaction_id,
      (item->>'period_id')::uuid,
      tx.job_card_number,
      (item->>'amount')::numeric(12,2),
      p_allocation_source,
      COALESCE(NULLIF(item->>'confidence',''),'confirmed'),
      NULLIF(item->>'note',''),
      p_user_id
    );
    inserted_count := inserted_count + 1;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'transaction_id', p_transaction_id,
    'allocated_amount', total,
    'unallocated_amount', tx.amount-total-v_refunded,
    'allocation_count', inserted_count
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid) TO service_role;

REVOKE ALL ON FUNCTION public.vbgramg_auto_allocate_unallocated_payments(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vbgramg_auto_allocate_after_charge_change() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_auto_allocate_unallocated_payments(text) TO service_role;

COMMENT ON FUNCTION public.vbgramg_auto_allocate_unallocated_payments(text) IS
  'Allocates existing unallocated payment balances to eligible contribution periods in FIFO order when a new eligible charge is recorded.';
