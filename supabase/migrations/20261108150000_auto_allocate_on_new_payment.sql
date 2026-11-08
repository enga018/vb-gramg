-- Run the shared period-level FIFO allocator when a new payment is recorded.
-- The allocator itself is shared with the existing new-charge trigger, so both
-- event paths use identical period/payment ordering and refund-adjusted balances.

CREATE OR REPLACE FUNCTION public.vbgramg_auto_allocate_after_payment_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
  IF NEW.entry_type <> 'payment'
     OR NEW.amount <= 0
     OR COALESCE(NEW.is_voided, false) THEN
    RETURN NEW;
  END IF;

  -- The shared allocator acquires the household lock and period locks, then
  -- consumes available payments against outstanding eligible periods FIFO.
  PERFORM public.vbgramg_auto_allocate_unallocated_payments(NEW.job_card_number);
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_vbgramg_auto_allocate_after_payment_insert
  ON public.vbgramg_charge_ledger;

CREATE TRIGGER trg_vbgramg_auto_allocate_after_payment_insert
AFTER INSERT
ON public.vbgramg_charge_ledger
FOR EACH ROW
WHEN (NEW.entry_type = 'payment' AND COALESCE(NEW.is_voided, false) = false)
EXECUTE FUNCTION public.vbgramg_auto_allocate_after_payment_insert();

REVOKE ALL ON FUNCTION public.vbgramg_auto_allocate_after_payment_insert() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public.vbgramg_auto_allocate_after_payment_insert() IS
  'Runs the shared period-level FIFO allocator immediately after a non-voided payment is inserted.';
