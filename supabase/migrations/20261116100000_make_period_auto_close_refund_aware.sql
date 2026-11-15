-- Make automatic period settlement reconciliation refund-aware.
-- Refunds are distributed proportionally across a payment's confirmed
-- allocations for the same job card, including allocations spanning periods.

CREATE OR REPLACE FUNCTION public.vbgramg_reconcile_period_auto_close(p_period_id uuid DEFAULT NULL)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_period record;
  v_closed integer := 0;
BEGIN
  FOR v_period IN
    SELECT p.id, p.reopened_at
    FROM public.vbgramg_periods p
    WHERE p.status = 'open'
      AND (p_period_id IS NULL OR p.id = p_period_id)
      AND (p.reopened_at IS NULL OR p.reopened_at <= pg_catalog.now() - interval '48 hours')
    ORDER BY p.id
    FOR UPDATE
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM public.vbgramg_charge_ledger c
      WHERE c.period_id = v_period.id
        AND c.entry_type IN ('charge','other_charge','sanitationFee')
        AND NOT COALESCE(c.is_voided,false)
        AND NOT (c.entry_type='charge' AND pg_catalog.btrim(COALESCE(c.note,''))='Return')
    ) THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.vbgramg_charge_ledger c
      WHERE c.period_id = v_period.id
        AND c.entry_type IN ('charge','other_charge','sanitationFee')
        AND COALESCE(c.is_deferred,false)
        AND NOT COALESCE(c.is_voided,false)
        AND NOT (c.entry_type='charge' AND pg_catalog.btrim(COALESCE(c.note,''))='Return')
    ) THEN
      CONTINUE;
    END IF;

    IF EXISTS (
      WITH charges AS (
        SELECT c.job_card_number, pg_catalog.sum(GREATEST(COALESCE(c.amount,0),0))::numeric(14,2) AS amount
        FROM public.vbgramg_charge_ledger c
        WHERE c.period_id = v_period.id
          AND c.entry_type IN ('charge','other_charge','sanitationFee')
          AND NOT COALESCE(c.is_voided,false)
          AND NOT COALESCE(c.is_deferred,false)
          AND NOT (c.entry_type='charge' AND pg_catalog.btrim(COALESCE(c.note,''))='Return')
        GROUP BY c.job_card_number
      ),
      refunds AS (
        SELECT r.payment_id, r.job_card_number, pg_catalog.sum(GREATEST(COALESCE(r.amount,0),0))::numeric(14,2) AS amount
        FROM public.vbgramg_payment_refund_reconciliations r
        JOIN public.vbgramg_charge_ledger refund ON refund.id = r.refund_id
        WHERE refund.entry_type = 'refund'
          AND NOT COALESCE(refund.is_voided,false)
        GROUP BY r.payment_id, r.job_card_number
      ),
      legacy_by_payment AS (
        SELECT a.transaction_id AS payment_id, a.job_card_number, a.period_id,
               pg_catalog.sum(GREATEST(COALESCE(a.amount,0),0))::numeric(14,2) AS period_amount
        FROM public.vbgramg_payment_allocations a
        JOIN public.vbgramg_charge_ledger pay ON pay.id = a.transaction_id
        WHERE a.confidence = 'confirmed'
          AND pay.entry_type = 'payment'
          AND NOT COALESCE(pay.is_voided,false)
          AND NOT EXISTS (
            SELECT 1 FROM public.vbgramg_charge_payment_allocations ca
            WHERE ca.payment_id = pay.id
          )
        GROUP BY a.transaction_id, a.job_card_number, a.period_id
      ),
      legacy_global AS (
        SELECT payment_id, job_card_number, pg_catalog.sum(period_amount)::numeric(14,2) AS total_amount
        FROM legacy_by_payment
        GROUP BY payment_id, job_card_number
      ),
      legacy_paid AS (
        SELECT l.job_card_number,
               pg_catalog.sum(
                 CASE WHEN g.total_amount > 0
                   THEN l.period_amount * GREATEST(g.total_amount - COALESCE(r.amount,0),0) / g.total_amount
                   ELSE 0 END
               )::numeric(14,2) AS amount
        FROM legacy_by_payment l
        JOIN legacy_global g USING (payment_id,job_card_number)
        LEFT JOIN refunds r USING (payment_id,job_card_number)
        WHERE l.period_id = v_period.id
        GROUP BY l.job_card_number
      ),
      charge_by_payment AS (
        SELECT ca.payment_id, charge.job_card_number, charge.period_id,
               pg_catalog.sum(GREATEST(COALESCE(ca.amount,0),0))::numeric(14,2) AS period_amount
        FROM public.vbgramg_charge_payment_allocations ca
        JOIN public.vbgramg_charge_ledger charge ON charge.id = ca.charge_id
        JOIN public.vbgramg_charge_ledger pay ON pay.id = ca.payment_id
        WHERE charge.entry_type IN ('charge','other_charge','sanitationFee')
          AND NOT COALESCE(charge.is_voided,false)
          AND NOT COALESCE(charge.is_deferred,false)
          AND NOT COALESCE(pay.is_voided,false)
          AND pay.entry_type = 'payment'
          AND ca.confidence = 'confirmed'
        GROUP BY ca.payment_id,charge.job_card_number,charge.period_id
      ),
      charge_global AS (
        SELECT payment_id,job_card_number,pg_catalog.sum(period_amount)::numeric(14,2) AS total_amount
        FROM charge_by_payment
        GROUP BY payment_id,job_card_number
      ),
      charge_paid AS (
        SELECT a.job_card_number,
               pg_catalog.sum(
                 CASE WHEN g.total_amount > 0
                   THEN a.period_amount * GREATEST(g.total_amount - COALESCE(r.amount,0),0) / g.total_amount
                   ELSE 0 END
               )::numeric(14,2) AS amount
        FROM charge_by_payment a
        JOIN charge_global g USING (payment_id,job_card_number)
        LEFT JOIN refunds r USING (payment_id,job_card_number)
        WHERE a.period_id = v_period.id
        GROUP BY a.job_card_number
      ),
      waived AS (
        SELECT w.job_card_number, pg_catalog.sum(GREATEST(COALESCE(w.amount,0),0))::numeric(14,2) AS amount
        FROM public.vbgramg_waiver_period_allocations w
        JOIN public.vbgramg_charge_ledger waiver ON waiver.id = w.waiver_id
        WHERE w.period_id = v_period.id
          AND waiver.entry_type IN ('charge_waiver','forgive')
          AND NOT COALESCE(waiver.is_voided,false)
        GROUP BY w.job_card_number
      )
      SELECT 1
      FROM charges c
      LEFT JOIN legacy_paid lp USING (job_card_number)
      LEFT JOIN charge_paid cp USING (job_card_number)
      LEFT JOIN waived w USING (job_card_number)
      WHERE c.amount - COALESCE(lp.amount,0) - COALESCE(cp.amount,0) - COALESCE(w.amount,0) > 0.001
    ) THEN
      CONTINUE;
    END IF;

    PERFORM pg_catalog.set_config('app.vbgramg_auto_closing','on',true);
    UPDATE public.vbgramg_periods
    SET status = 'closed',
        closed_at = pg_catalog.now(),
        updated_at = pg_catalog.now()
    WHERE id = v_period.id
      AND status = 'open';
    IF FOUND THEN v_closed := v_closed + 1; END IF;
    PERFORM pg_catalog.set_config('app.vbgramg_auto_closing','off',true);
  END LOOP;
  RETURN v_closed;
END;
$$;
