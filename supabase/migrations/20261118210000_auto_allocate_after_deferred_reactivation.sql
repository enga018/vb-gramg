-- Re-run the shared FIFO allocator when a deferred contribution charge becomes eligible again.
-- Payments recorded while a charge was deferred remain available and should be
-- allocated as soon as that charge is restored to an eligible state.

CREATE OR REPLACE FUNCTION public.vbgramg_auto_allocate_after_deferred_charge_reactivation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  -- Change Period deliberately stages replacement FTO rows as deferred and
  -- restores their status inside one protected rebuild. Do not allocate from
  -- this intermediate state; that workflow owns its own reconciliation.
  IF pg_catalog.current_setting('app.vbgramg_allow_fto_period_rebuild', true) = 'on'
     OR OLD.is_deferred IS DISTINCT FROM TRUE
     OR NEW.is_deferred IS DISTINCT FROM FALSE
     OR NEW.period_id IS NULL
     OR NEW.entry_type NOT IN ('charge', 'other_charge', 'sanitationFee')
     OR COALESCE(NEW.is_voided, false)
     OR (NEW.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(NEW.note, '')) = 'Return') THEN
    RETURN NEW;
  END IF;

  PERFORM public.vbgramg_auto_allocate_unallocated_payments(NEW.job_card_number);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_vbgramg_auto_allocate_after_deferred_charge_reactivation
  ON public.vbgramg_charge_ledger;

CREATE TRIGGER trg_vbgramg_auto_allocate_after_deferred_charge_reactivation
AFTER UPDATE OF is_deferred
ON public.vbgramg_charge_ledger
FOR EACH ROW
WHEN (
  OLD.is_deferred IS TRUE
  AND NEW.is_deferred IS FALSE
)
EXECUTE FUNCTION public.vbgramg_auto_allocate_after_deferred_charge_reactivation();

REVOKE ALL ON FUNCTION public.vbgramg_auto_allocate_after_deferred_charge_reactivation()
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.vbgramg_auto_allocate_after_deferred_charge_reactivation() IS
  'Runs the shared FIFO allocator when a deferred contribution charge is restored to eligible status.';
