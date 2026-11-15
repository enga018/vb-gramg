-- Automatic contribution-period closure with a 48-hour administrator reopening window.
ALTER TABLE public.vbgramg_periods
  ADD COLUMN IF NOT EXISTS reopened_at timestamptz;

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
    -- An empty period, or one whose charges have all been voided, remains
    -- open and deletable. Deferred active charges always prevent closure.
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

    -- Reconcile each job card independently. Confirmed legacy period
    -- allocations and charge-level allocations are both supported. When a
    -- payment has charge-level allocations, its legacy allocations are not
    -- counted again.
    IF EXISTS (
      WITH charges AS (
        SELECT c.job_card_number, pg_catalog.sum(c.amount)::numeric(14,2) AS amount
        FROM public.vbgramg_charge_ledger c
        WHERE c.period_id = v_period.id
          AND c.entry_type IN ('charge','other_charge','sanitationFee')
          AND NOT COALESCE(c.is_voided,false)
          AND NOT COALESCE(c.is_deferred,false)
          AND NOT (c.entry_type='charge' AND pg_catalog.btrim(COALESCE(c.note,''))='Return')
        GROUP BY c.job_card_number
      ),
      legacy_paid AS (
        SELECT a.job_card_number, pg_catalog.sum(a.amount)::numeric(14,2) AS amount
        FROM public.vbgramg_payment_allocations a
        JOIN public.vbgramg_charge_ledger pay ON pay.id = a.transaction_id
        WHERE a.period_id = v_period.id
          AND a.confidence = 'confirmed'
          AND pay.entry_type = 'payment'
          AND NOT COALESCE(pay.is_voided,false)
          AND NOT EXISTS (
            SELECT 1 FROM public.vbgramg_charge_payment_allocations ca
            WHERE ca.payment_id = pay.id
          )
        GROUP BY a.job_card_number
      ),
      charge_paid AS (
        SELECT charge.job_card_number, pg_catalog.sum(ca.amount)::numeric(14,2) AS amount
        FROM public.vbgramg_charge_payment_allocations ca
        JOIN public.vbgramg_charge_ledger charge ON charge.id = ca.charge_id
        JOIN public.vbgramg_charge_ledger pay ON pay.id = ca.payment_id
        WHERE charge.period_id = v_period.id
          AND charge.entry_type IN ('charge','other_charge','sanitationFee')
          AND NOT COALESCE(charge.is_voided,false)
          AND NOT COALESCE(charge.is_deferred,false)
          AND NOT COALESCE(pay.is_voided,false)
          AND pay.entry_type = 'payment'
          AND ca.confidence = 'confirmed'
        GROUP BY charge.job_card_number
      ),
      waived AS (
        SELECT w.job_card_number, pg_catalog.sum(w.amount)::numeric(14,2) AS amount
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

CREATE OR REPLACE FUNCTION public.vbgramg_guard_manual_period_close()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF OLD.status = 'open'
     AND NEW.status = 'closed'
     AND COALESCE(pg_catalog.current_setting('app.vbgramg_auto_closing',true),'off') <> 'on' THEN
    RAISE EXCEPTION 'Periods close automatically when all active charges are settled or voided.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vbgramg_guard_manual_period_close ON public.vbgramg_periods;
CREATE TRIGGER trg_vbgramg_guard_manual_period_close
BEFORE UPDATE OF status ON public.vbgramg_periods
FOR EACH ROW EXECUTE FUNCTION public.vbgramg_guard_manual_period_close();

CREATE OR REPLACE FUNCTION public.vbgramg_period_auto_close_change_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_period_id uuid;
  v_charge_id uuid;
BEGIN
  IF TG_TABLE_NAME = 'vbgramg_charge_ledger' THEN
    IF TG_OP <> 'INSERT' THEN
      PERFORM public.vbgramg_reconcile_period_auto_close(OLD.period_id);
      IF OLD.entry_type = 'payment' THEN
        FOR v_period_id IN
          SELECT DISTINCT a.period_id FROM public.vbgramg_payment_allocations a WHERE a.transaction_id = OLD.id
          UNION
          SELECT DISTINCT c.period_id FROM public.vbgramg_charge_payment_allocations ca
          JOIN public.vbgramg_charge_ledger c ON c.id = ca.charge_id
          WHERE ca.payment_id = OLD.id
        LOOP PERFORM public.vbgramg_reconcile_period_auto_close(v_period_id); END LOOP;
      END IF;
    END IF;
    IF TG_OP <> 'DELETE' THEN
      PERFORM public.vbgramg_reconcile_period_auto_close(NEW.period_id);
      IF NEW.entry_type = 'payment' THEN
        FOR v_period_id IN
          SELECT DISTINCT a.period_id FROM public.vbgramg_payment_allocations a WHERE a.transaction_id = NEW.id
          UNION
          SELECT DISTINCT c.period_id FROM public.vbgramg_charge_payment_allocations ca
          JOIN public.vbgramg_charge_ledger c ON c.id = ca.charge_id
          WHERE ca.payment_id = NEW.id
        LOOP PERFORM public.vbgramg_reconcile_period_auto_close(v_period_id); END LOOP;
      END IF;
    END IF;
  ELSIF TG_TABLE_NAME IN ('vbgramg_payment_allocations','vbgramg_waiver_period_allocations') THEN
    IF TG_OP <> 'INSERT' THEN
      PERFORM public.vbgramg_reconcile_period_auto_close(OLD.period_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
      PERFORM public.vbgramg_reconcile_period_auto_close(NEW.period_id);
    END IF;
  ELSIF TG_TABLE_NAME = 'vbgramg_charge_payment_allocations' THEN
    IF TG_OP <> 'INSERT' THEN
      SELECT period_id INTO v_period_id FROM public.vbgramg_charge_ledger WHERE id = OLD.charge_id;
      PERFORM public.vbgramg_reconcile_period_auto_close(v_period_id);
    END IF;
    IF TG_OP <> 'DELETE' THEN
      SELECT period_id INTO v_period_id FROM public.vbgramg_charge_ledger WHERE id = NEW.charge_id;
      PERFORM public.vbgramg_reconcile_period_auto_close(v_period_id);
    END IF;
  ELSIF TG_TABLE_NAME = 'vbgramg_payment_refund_reconciliations' THEN
    IF TG_OP <> 'INSERT' THEN
      FOR v_period_id IN
        SELECT DISTINCT a.period_id FROM public.vbgramg_payment_allocations a WHERE a.transaction_id = OLD.payment_id
        UNION
        SELECT DISTINCT c.period_id FROM public.vbgramg_charge_payment_allocations ca
        JOIN public.vbgramg_charge_ledger c ON c.id = ca.charge_id
        WHERE ca.payment_id = OLD.payment_id
      LOOP PERFORM public.vbgramg_reconcile_period_auto_close(v_period_id); END LOOP;
    END IF;
    IF TG_OP <> 'DELETE' THEN
      FOR v_period_id IN
        SELECT DISTINCT a.period_id FROM public.vbgramg_payment_allocations a WHERE a.transaction_id = NEW.payment_id
        UNION
        SELECT DISTINCT c.period_id FROM public.vbgramg_charge_payment_allocations ca
        JOIN public.vbgramg_charge_ledger c ON c.id = ca.charge_id
        WHERE ca.payment_id = NEW.payment_id
      LOOP PERFORM public.vbgramg_reconcile_period_auto_close(v_period_id); END LOOP;
    END IF;
  END IF;
  IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS zzz_vbgramg_period_auto_close_ledger ON public.vbgramg_charge_ledger;
CREATE TRIGGER zzz_vbgramg_period_auto_close_ledger
AFTER INSERT OR UPDATE OR DELETE ON public.vbgramg_charge_ledger
FOR EACH ROW EXECUTE FUNCTION public.vbgramg_period_auto_close_change_trigger();

DROP TRIGGER IF EXISTS zzz_vbgramg_period_auto_close_legacy_allocations ON public.vbgramg_payment_allocations;
CREATE TRIGGER zzz_vbgramg_period_auto_close_legacy_allocations
AFTER INSERT OR UPDATE OR DELETE ON public.vbgramg_payment_allocations
FOR EACH ROW EXECUTE FUNCTION public.vbgramg_period_auto_close_change_trigger();

DROP TRIGGER IF EXISTS zzz_vbgramg_period_auto_close_charge_allocations ON public.vbgramg_charge_payment_allocations;
CREATE TRIGGER zzz_vbgramg_period_auto_close_charge_allocations
AFTER INSERT OR UPDATE OR DELETE ON public.vbgramg_charge_payment_allocations
FOR EACH ROW EXECUTE FUNCTION public.vbgramg_period_auto_close_change_trigger();

DROP TRIGGER IF EXISTS zzz_vbgramg_period_auto_close_waivers ON public.vbgramg_waiver_period_allocations;
CREATE TRIGGER zzz_vbgramg_period_auto_close_waivers
AFTER INSERT OR UPDATE OR DELETE ON public.vbgramg_waiver_period_allocations
FOR EACH ROW EXECUTE FUNCTION public.vbgramg_period_auto_close_change_trigger();

DROP TRIGGER IF EXISTS zzz_vbgramg_period_auto_close_refunds ON public.vbgramg_payment_refund_reconciliations;
CREATE TRIGGER zzz_vbgramg_period_auto_close_refunds
AFTER INSERT OR UPDATE OR DELETE ON public.vbgramg_payment_refund_reconciliations
FOR EACH ROW EXECUTE FUNCTION public.vbgramg_period_auto_close_change_trigger();

SELECT cron.schedule(
  'vbgramg-auto-close-periods',
  '* * * * *',
  'SELECT public.vbgramg_reconcile_period_auto_close();'
);
