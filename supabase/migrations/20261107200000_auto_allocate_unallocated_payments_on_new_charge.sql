-- Automatically consume a job card's existing unallocated payments when a new eligible
-- contribution charge is added or an active charge amount increases.
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

  -- Serialize every allocation decision for this job card with the existing
  -- contribution write paths.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-contribution:' || v_card, 0)
  );

  -- Exempt cards must never receive automatic contribution allocations.
  IF EXISTS (
    SELECT 1
    FROM public.vbgramg_contribution_exemptions e
    WHERE pg_catalog.btrim(e.job_card_number) = v_card
  ) THEN
    RETURN pg_catalog.jsonb_build_object('allocated_amount', 0, 'allocation_count', 0, 'skipped', 'exempt');
  END IF;

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
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('contribution:' || v_card || ':' || v_period.id::text, 0)
    );

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

  IF TG_OP = 'UPDATE' THEN
    -- Do not auto-allocate when a deferred/voided charge is restored. Only an
    -- increase to a charge that was already active can consume spare payments.
    IF COALESCE(OLD.is_deferred, false)
       OR COALESCE(OLD.is_voided, false)
       OR OLD.job_card_number IS DISTINCT FROM NEW.job_card_number
       OR OLD.period_id IS DISTINCT FROM NEW.period_id
       OR NEW.amount <= OLD.amount THEN
      RETURN NEW;
    END IF;
  END IF;

  PERFORM public.vbgramg_auto_allocate_unallocated_payments(NEW.job_card_number);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_vbgramg_auto_allocate_after_charge_change
  ON public.vbgramg_charge_ledger;

CREATE TRIGGER trg_vbgramg_auto_allocate_after_charge_change
AFTER INSERT OR UPDATE OF amount, is_deferred, is_voided, period_id, entry_type, job_card_number, note
ON public.vbgramg_charge_ledger
FOR EACH ROW
EXECUTE FUNCTION public.vbgramg_auto_allocate_after_charge_change();

REVOKE ALL ON FUNCTION public.vbgramg_auto_allocate_unallocated_payments(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vbgramg_auto_allocate_after_charge_change() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_auto_allocate_unallocated_payments(text) TO service_role;

COMMENT ON FUNCTION public.vbgramg_auto_allocate_unallocated_payments(text) IS
  'Allocates existing unallocated payment balances to eligible contribution periods in FIFO order when a new eligible charge is recorded or an active charge increases.';
