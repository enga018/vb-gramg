-- Activate the existing contribution charge when an imported Deferred FTO
-- transaction is reconciled as Processed. The ledger's own reactivation trigger
-- then performs the established FIFO payment allocation in this same transaction.
-- Rows without a ledger link are intentionally left untouched.

CREATE OR REPLACE FUNCTION public.vbgramg_activate_deferred_fto_charge_on_processed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF lower(pg_catalog.btrim(coalesce(OLD.status, ''))) <> 'blank'
     OR lower(pg_catalog.btrim(coalesce(NEW.status, ''))) <> 'processed'
     OR NEW.ledger_entry_id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.vbgramg_charge_ledger AS ledger
  SET is_deferred = false
  WHERE ledger.id = NEW.ledger_entry_id
    AND ledger.entry_type IN ('charge', 'other_charge', 'sanitationFee')
    AND ledger.is_deferred IS TRUE
    AND ledger.is_voided IS FALSE;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_vbgramg_activate_deferred_fto_charge_on_processed
  ON public.vbgramg_fto_transactions;

CREATE TRIGGER trg_vbgramg_activate_deferred_fto_charge_on_processed
AFTER UPDATE OF status
ON public.vbgramg_fto_transactions
FOR EACH ROW
WHEN (
  lower(btrim(coalesce(OLD.status, ''))) = 'blank'
  AND lower(btrim(coalesce(NEW.status, ''))) = 'processed'
)
EXECUTE FUNCTION public.vbgramg_activate_deferred_fto_charge_on_processed();

REVOKE ALL ON FUNCTION public.vbgramg_activate_deferred_fto_charge_on_processed()
  FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.vbgramg_activate_deferred_fto_charge_on_processed() IS
  'Activates an existing linked contribution charge after a Deferred FTO transaction becomes Processed; the charge reactivation trigger performs FIFO allocation.';
