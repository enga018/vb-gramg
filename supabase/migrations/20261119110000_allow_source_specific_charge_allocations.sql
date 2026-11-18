-- Allow source-specific charge-level allocation rows for one payment/charge pair.
-- The validation trigger continues to enforce aggregate payment and charge capacity
-- across every source, while FIFO rebuilds can replace only fifo_auto rows.

ALTER TABLE public.vbgramg_charge_payment_allocations
  DROP CONSTRAINT IF EXISTS vbgramg_charge_payment_allocations_payment_charge_unique;

ALTER TABLE public.vbgramg_charge_payment_allocations
  ADD CONSTRAINT vbgramg_charge_payment_allocations_payment_charge_source_unique
  UNIQUE (payment_id, charge_id, allocation_source);

COMMENT ON CONSTRAINT vbgramg_charge_payment_allocations_payment_charge_source_unique
  ON public.vbgramg_charge_payment_allocations IS
  'Allows distinct allocation sources for one payment/charge pair while preventing duplicate rows within a source.';
