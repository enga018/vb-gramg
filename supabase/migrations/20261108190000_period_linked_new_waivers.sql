-- Period-linked allocation for newly recorded waivers only.
-- Existing waiver ledger rows are left untouched and are treated as legacy FIFO
-- reductions when calculating the amount available for a new waiver.

CREATE TABLE IF NOT EXISTS public.vbgramg_waiver_period_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  waiver_id uuid NOT NULL REFERENCES public.vbgramg_charge_ledger(id) ON DELETE RESTRICT,
  period_id uuid NOT NULL REFERENCES public.vbgramg_periods(id) ON DELETE RESTRICT,
  job_card_number text NOT NULL,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  allocation_source text NOT NULL DEFAULT 'fifo_auto'
    CHECK (allocation_source IN ('fifo_auto')),
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (waiver_id, period_id)
);

CREATE INDEX IF NOT EXISTS idx_vbgramg_waiver_period_allocations_period
  ON public.vbgramg_waiver_period_allocations(period_id);
CREATE INDEX IF NOT EXISTS idx_vbgramg_waiver_period_allocations_waiver
  ON public.vbgramg_waiver_period_allocations(waiver_id);
CREATE INDEX IF NOT EXISTS idx_vbgramg_waiver_period_allocations_job_card
  ON public.vbgramg_waiver_period_allocations(job_card_number);

ALTER TABLE public.vbgramg_waiver_period_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vbgramg_waiver_period_allocations FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.vbgramg_waiver_period_allocations FROM service_role;
GRANT SELECT ON public.vbgramg_waiver_period_allocations TO service_role;

COMMENT ON TABLE public.vbgramg_waiver_period_allocations IS
  'Period-level FIFO distribution for new waiver ledger entries. Historical waiver entries are not backfilled.';

-- New waiver allocations reduce the eligible period balance before any later
-- unallocated payment is consumed. This replaces only the shared allocator;
-- payment and charge triggers continue to use the same function.
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
  v_period_waived numeric(14,2);
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

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-contribution:' || v_card, 0)
  );

  IF EXISTS (
    SELECT 1 FROM public.vbgramg_contribution_exemptions e
    WHERE pg_catalog.btrim(e.job_card_number) = v_card
  ) THEN
    RETURN pg_catalog.jsonb_build_object('allocated_amount', 0, 'allocation_count', 0, 'skipped', 'exempt');
  END IF;

  FOR v_period IN
    SELECT p.id
    FROM public.vbgramg_periods p
    WHERE EXISTS (
      SELECT 1 FROM public.vbgramg_charge_ledger c
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

  FOR v_period IN
    SELECT p.id
    FROM public.vbgramg_periods p
    WHERE EXISTS (
      SELECT 1 FROM public.vbgramg_charge_ledger c
      WHERE c.job_card_number = v_card
        AND c.period_id = p.id
        AND c.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND COALESCE(c.is_deferred, false) = false
        AND COALESCE(c.is_voided, false) = false
        AND NOT (c.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(c.note, '')) = 'Return')
    )
    ORDER BY COALESCE(p.contribution_month, p.period_date) ASC NULLS LAST,
             p.created_at ASC, p.id ASC
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
    JOIN public.vbgramg_charge_ledger payment ON payment.id = a.transaction_id
    WHERE a.job_card_number = v_card
      AND a.period_id = v_period.id
      AND payment.entry_type = 'payment'
      AND COALESCE(payment.is_voided, false) = false;

    SELECT COALESCE(pg_catalog.sum(w.amount), 0)::numeric(14,2)
      INTO v_period_waived
    FROM public.vbgramg_waiver_period_allocations w
    JOIN public.vbgramg_charge_ledger waiver ON waiver.id = w.waiver_id
    WHERE w.job_card_number = v_card
      AND w.period_id = v_period.id
      AND waiver.entry_type IN ('charge_waiver', 'forgive')
      AND COALESCE(waiver.is_voided, false) = false;

    v_period_due := GREATEST(v_period_charges - v_period_allocated - v_period_waived, 0);
    IF v_period_due <= 0 THEN
      CONTINUE;
    END IF;

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
        COALESCE((SELECT pg_catalog.sum(a.amount)
          FROM public.vbgramg_payment_allocations a
          WHERE a.transaction_id = v_payment.id), 0)::numeric(14,2),
        COALESCE((SELECT pg_catalog.sum(r.amount)
          FROM public.vbgramg_payment_refund_reconciliations r
          WHERE r.payment_id = v_payment.id), 0)::numeric(14,2)
      INTO v_payment_allocated, v_payment_refunded;

      v_payment_available := GREATEST(v_payment.amount - v_payment_allocated - v_payment_refunded, 0);
      v_take := LEAST(v_payment_available, v_period_due);
      IF v_take <= 0 THEN
        CONTINUE;
      END IF;

      SELECT a.amount INTO v_allocation_before
      FROM public.vbgramg_payment_allocations a
      WHERE a.transaction_id = v_payment.id AND a.period_id = v_period.id;
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
        ledger_entry_id, job_card_number, action, actor_user_id, before_data, after_data
      ) VALUES (
        v_payment.id, v_card, 'automatic_fifo_allocation', NULL,
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

REVOKE ALL ON FUNCTION public.vbgramg_auto_allocate_unallocated_payments(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_auto_allocate_unallocated_payments(text) TO service_role;

-- The trigger runs after the existing transaction RPC inserts a new waiver.
-- It first allocates any available payment credit, then applies the waiver FIFO
-- to the remaining unpaid balance. Historical waivers are accounted for as a
-- legacy aggregate but are never modified or backfilled.
CREATE OR REPLACE FUNCTION public.vbgramg_allocate_new_waiver_fifo()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_period record;
  v_card text := pg_catalog.btrim(NEW.job_card_number);
  v_period_charges numeric(14,2);
  v_period_paid numeric(14,2);
  v_period_new_waived numeric(14,2);
  v_period_due numeric(14,2);
  v_legacy_waiver_remaining numeric(14,2) := 0;
  v_legacy_take numeric(14,2);
  v_new_waiver_remaining numeric(14,2) := NEW.amount;
  v_take numeric(14,2);
  v_total_available numeric(14,2) := 0;
  v_allocation_count integer := 0;
BEGIN
  IF NEW.entry_type NOT IN ('charge_waiver', 'forgive')
     OR COALESCE(NEW.is_voided, false) THEN
    RETURN NEW;
  END IF;

  IF v_card = '' OR NEW.amount IS NULL OR NEW.amount <= 0 THEN
    RAISE EXCEPTION 'A new waiver requires a valid job card and positive amount'
      USING ERRCODE = '23514';
  END IF;

  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-contribution:' || v_card, 0)
  );

  IF EXISTS (
    SELECT 1 FROM public.vbgramg_contribution_exemptions e
    WHERE pg_catalog.btrim(e.job_card_number) = v_card
  ) THEN
    RAISE EXCEPTION 'An exempt job card cannot receive a new waiver'
      USING ERRCODE = '23514';
  END IF;

  -- All currently eligible charges must have a period identity. Do not guess
  -- where a new waiver belongs when legacy unlinked charges remain.
  IF EXISTS (
    SELECT 1 FROM public.vbgramg_charge_ledger c
    WHERE c.job_card_number = v_card
      AND c.entry_type IN ('charge', 'other_charge', 'sanitationFee')
      AND COALESCE(c.is_deferred, false) = false
      AND COALESCE(c.is_voided, false) = false
      AND NOT (c.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(c.note, '')) = 'Return')
      AND c.period_id IS NULL
  ) THEN
    RAISE EXCEPTION 'A new waiver cannot be allocated while eligible charges are missing a period link'
      USING ERRCODE = '23514';
  END IF;

  -- Ensure any existing unallocated payment credit is consumed before waiver
  -- eligibility is measured. This call shares the same household lock.
  PERFORM public.vbgramg_auto_allocate_unallocated_payments(v_card);

  -- Lock eligible periods in the same stable UUID order as the payment allocator.
  FOR v_period IN
    SELECT p.id
    FROM public.vbgramg_periods p
    WHERE EXISTS (
      SELECT 1 FROM public.vbgramg_charge_ledger c
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

  -- Historical waivers remain unchanged. Subtract amounts already represented
  -- by period allocations; only the unrepresented legacy remainder is applied
  -- FIFO before distributing this newly inserted waiver.
  SELECT GREATEST(
    COALESCE((
      SELECT pg_catalog.sum(l.amount)
      FROM public.vbgramg_charge_ledger l
      WHERE l.job_card_number = v_card
        AND l.id <> NEW.id
        AND l.entry_type IN ('charge_waiver', 'forgive')
        AND COALESCE(l.is_voided, false) = false
    ), 0)
    -
    COALESCE((
      SELECT pg_catalog.sum(w.amount)
      FROM public.vbgramg_waiver_period_allocations w
      JOIN public.vbgramg_charge_ledger linked ON linked.id = w.waiver_id
      WHERE w.job_card_number = v_card
        AND linked.entry_type IN ('charge_waiver', 'forgive')
        AND COALESCE(linked.is_voided, false) = false
    ), 0),
    0
  )::numeric(14,2)
  INTO v_legacy_waiver_remaining;

  FOR v_period IN
    SELECT p.id
    FROM public.vbgramg_periods p
    WHERE EXISTS (
      SELECT 1 FROM public.vbgramg_charge_ledger c
      WHERE c.job_card_number = v_card
        AND c.period_id = p.id
        AND c.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND COALESCE(c.is_deferred, false) = false
        AND COALESCE(c.is_voided, false) = false
        AND NOT (c.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(c.note, '')) = 'Return')
    )
    ORDER BY COALESCE(p.contribution_month, p.period_date) ASC NULLS LAST,
             p.created_at ASC, p.id ASC
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
      INTO v_period_paid
    FROM public.vbgramg_payment_allocations a
    JOIN public.vbgramg_charge_ledger payment ON payment.id = a.transaction_id
    WHERE a.job_card_number = v_card
      AND a.period_id = v_period.id
      AND payment.entry_type = 'payment'
      AND COALESCE(payment.is_voided, false) = false;

    SELECT COALESCE(pg_catalog.sum(w.amount), 0)::numeric(14,2)
      INTO v_period_new_waived
    FROM public.vbgramg_waiver_period_allocations w
    JOIN public.vbgramg_charge_ledger waiver ON waiver.id = w.waiver_id
    WHERE w.job_card_number = v_card
      AND w.period_id = v_period.id
      AND waiver.entry_type IN ('charge_waiver', 'forgive')
      AND COALESCE(waiver.is_voided, false) = false;

    v_period_due := GREATEST(v_period_charges - v_period_paid - v_period_new_waived, 0);
    v_legacy_take := LEAST(v_legacy_waiver_remaining, v_period_due);
    v_legacy_waiver_remaining := v_legacy_waiver_remaining - v_legacy_take;
    v_period_due := v_period_due - v_legacy_take;
    v_total_available := v_total_available + v_period_due;

    v_take := LEAST(v_new_waiver_remaining, v_period_due);
    IF v_take > 0 THEN
      INSERT INTO public.vbgramg_waiver_period_allocations (
        waiver_id, period_id, job_card_number, amount, allocation_source, created_by
      ) VALUES (
        NEW.id, v_period.id, v_card, v_take, 'fifo_auto', NEW.created_by
      );

      INSERT INTO public.vbgramg_ledger_audit (
        ledger_entry_id, job_card_number, action, actor_user_id, before_data, after_data
      ) VALUES (
        NEW.id, v_card, 'new_waiver_fifo_allocation', NEW.created_by,
        pg_catalog.jsonb_build_object(
          'period_id', v_period.id,
          'waiver_unallocated_before', v_new_waiver_remaining
        ),
        pg_catalog.jsonb_build_object(
          'period_id', v_period.id,
          'amount_allocated', v_take,
          'waiver_unallocated_after', v_new_waiver_remaining - v_take
        )
      );

      v_new_waiver_remaining := v_new_waiver_remaining - v_take;
      v_allocation_count := v_allocation_count + 1;
    END IF;
  END LOOP;

  IF v_new_waiver_remaining > 0.001 THEN
    RAISE EXCEPTION 'Waiver amount exceeds the unpaid eligible balance. Available to waive: %',
      pg_catalog.to_char(v_total_available, 'FM999999990.00')
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_vbgramg_allocate_new_waiver_fifo ON public.vbgramg_charge_ledger;
CREATE TRIGGER trg_vbgramg_allocate_new_waiver_fifo
AFTER INSERT ON public.vbgramg_charge_ledger
FOR EACH ROW
WHEN (NEW.entry_type IN ('charge_waiver', 'forgive'))
EXECUTE FUNCTION public.vbgramg_allocate_new_waiver_fifo();

REVOKE ALL ON FUNCTION public.vbgramg_allocate_new_waiver_fifo() FROM PUBLIC, anon, authenticated;


-- Until a dedicated waiver-revision workflow exists, prevent changes that would
-- invalidate an already distributed new waiver. Historical waiver rows remain editable.
CREATE OR REPLACE FUNCTION public.vbgramg_guard_allocated_waiver_edit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF OLD.entry_type IN ('charge_waiver', 'forgive')
     AND EXISTS (
       SELECT 1 FROM public.vbgramg_waiver_period_allocations w
       WHERE w.waiver_id = OLD.id
     )
     AND (
       NEW.amount IS DISTINCT FROM OLD.amount
       OR NEW.entry_type IS DISTINCT FROM OLD.entry_type
       OR NEW.job_card_number IS DISTINCT FROM OLD.job_card_number
       OR COALESCE(NEW.is_voided, false) IS DISTINCT FROM COALESCE(OLD.is_voided, false)
     ) THEN
    RAISE EXCEPTION 'This new waiver has period allocations and cannot be edited or voided until waiver revision is implemented.'
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_vbgramg_guard_allocated_waiver_edit ON public.vbgramg_charge_ledger;
CREATE TRIGGER trg_vbgramg_guard_allocated_waiver_edit
BEFORE UPDATE ON public.vbgramg_charge_ledger
FOR EACH ROW
EXECUTE FUNCTION public.vbgramg_guard_allocated_waiver_edit();

REVOKE ALL ON FUNCTION public.vbgramg_guard_allocated_waiver_edit() FROM PUBLIC, anon, authenticated;
