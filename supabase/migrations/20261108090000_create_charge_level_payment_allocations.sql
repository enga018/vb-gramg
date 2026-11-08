-- Introduce charge-level current allocation rows without changing legacy period allocations.
-- Historical mapping and allocator cutover are deliberately separate migrations.

CREATE TABLE IF NOT EXISTS public.vbgramg_charge_payment_allocations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL REFERENCES public.vbgramg_charge_ledger(id) ON DELETE RESTRICT,
  charge_id uuid NOT NULL REFERENCES public.vbgramg_charge_ledger(id) ON DELETE RESTRICT,
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  allocation_source text NOT NULL DEFAULT 'manual'
    CHECK (allocation_source IN ('fifo_auto','manual','historical_evidence','historical_fifo_reviewed')),
  confidence text NOT NULL DEFAULT 'confirmed'
    CHECK (confidence IN ('confirmed','probable','review_required')),
  note text,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vbgramg_charge_payment_allocations_distinct_entries
    CHECK (payment_id <> charge_id),
  CONSTRAINT vbgramg_charge_payment_allocations_payment_charge_unique
    UNIQUE (payment_id, charge_id)
);

CREATE INDEX IF NOT EXISTS idx_vbgramg_charge_payment_allocations_payment
  ON public.vbgramg_charge_payment_allocations(payment_id);
CREATE INDEX IF NOT EXISTS idx_vbgramg_charge_payment_allocations_charge
  ON public.vbgramg_charge_payment_allocations(charge_id);

ALTER TABLE public.vbgramg_charge_payment_allocations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.vbgramg_charge_payment_allocations FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vbgramg_charge_payment_allocations TO service_role;

CREATE OR REPLACE FUNCTION public.vbgramg_validate_charge_payment_allocation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_payment public.vbgramg_charge_ledger%ROWTYPE;
  v_charge public.vbgramg_charge_ledger%ROWTYPE;
  v_payment_allocated numeric(14,2);
  v_refunded numeric(14,2);
  v_charge_allocated numeric(14,2);
  v_card text;
BEGIN
  IF TG_OP = 'UPDATE' AND (
    OLD.payment_id IS DISTINCT FROM NEW.payment_id
    OR OLD.charge_id IS DISTINCT FROM NEW.charge_id
  ) THEN
    RAISE EXCEPTION 'Payment and charge references are immutable; replace the allocation instead';
  END IF;

  SELECT l.job_card_number INTO v_card
  FROM public.vbgramg_charge_ledger l
  WHERE l.id = NEW.payment_id;

  IF NOT FOUND OR NULLIF(pg_catalog.btrim(v_card), '') IS NULL THEN
    RAISE EXCEPTION 'Payment transaction was not found';
  END IF;

  -- Serialize all allocation changes for a job card before locking ledger rows.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-contribution:' || pg_catalog.btrim(v_card), 0)
  );

  SELECT * INTO v_payment
  FROM public.vbgramg_charge_ledger
  WHERE id = NEW.payment_id
  FOR UPDATE;

  SELECT * INTO v_charge
  FROM public.vbgramg_charge_ledger
  WHERE id = NEW.charge_id
  FOR UPDATE;

  IF NOT FOUND OR v_charge.id IS NULL THEN
    RAISE EXCEPTION 'Target contribution charge was not found';
  END IF;

  IF v_payment.entry_type IS DISTINCT FROM 'payment' THEN
    RAISE EXCEPTION 'Only payment transactions can fund a charge allocation';
  END IF;

  IF v_charge.entry_type NOT IN ('charge','other_charge','sanitationFee')
     OR (v_charge.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(v_charge.note,'')) = 'Return') THEN
    RAISE EXCEPTION 'Target ledger entry is not an allocatable contribution charge';
  END IF;

  IF v_payment.job_card_number IS DISTINCT FROM v_charge.job_card_number
     OR pg_catalog.btrim(v_payment.job_card_number) IS DISTINCT FROM pg_catalog.btrim(v_charge.job_card_number) THEN
    RAISE EXCEPTION 'Payment and charge must belong to the same job card';
  END IF;

  IF COALESCE(v_payment.is_voided,false) OR COALESCE(v_charge.is_voided,false)
     OR COALESCE(v_charge.is_deferred,false) THEN
    RAISE EXCEPTION 'Voided payments, voided charges, and deferred charges cannot be allocated';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vbgramg_contribution_exemptions e
    WHERE pg_catalog.btrim(e.job_card_number) = pg_catalog.btrim(v_card)
  ) THEN
    RAISE EXCEPTION 'Exempt job cards cannot receive contribution allocations';
  END IF;

  SELECT COALESCE(pg_catalog.sum(a.amount),0)::numeric(14,2)
    INTO v_payment_allocated
  FROM public.vbgramg_charge_payment_allocations a
  WHERE a.payment_id = NEW.payment_id
    AND a.id IS DISTINCT FROM NEW.id;

  SELECT COALESCE(pg_catalog.sum(r.amount),0)::numeric(14,2)
    INTO v_refunded
  FROM public.vbgramg_payment_refund_reconciliations r
  WHERE r.payment_id = NEW.payment_id;

  IF v_payment_allocated + NEW.amount + v_refunded > v_payment.amount + 0.001 THEN
    RAISE EXCEPTION 'Charge allocations plus refunds exceed the available payment amount';
  END IF;

  SELECT COALESCE(pg_catalog.sum(a.amount),0)::numeric(14,2)
    INTO v_charge_allocated
  FROM public.vbgramg_charge_payment_allocations a
  WHERE a.charge_id = NEW.charge_id
    AND a.id IS DISTINCT FROM NEW.id;

  IF v_charge_allocated + NEW.amount > v_charge.amount + 0.001 THEN
    RAISE EXCEPTION 'Allocations exceed the target charge amount';
  END IF;

  NEW.updated_at := pg_catalog.now();
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_vbgramg_validate_charge_payment_allocation
  ON public.vbgramg_charge_payment_allocations;
CREATE TRIGGER trg_vbgramg_validate_charge_payment_allocation
BEFORE INSERT OR UPDATE ON public.vbgramg_charge_payment_allocations
FOR EACH ROW EXECUTE FUNCTION public.vbgramg_validate_charge_payment_allocation();

REVOKE ALL ON FUNCTION public.vbgramg_validate_charge_payment_allocation() FROM PUBLIC, anon, authenticated;

COMMENT ON TABLE public.vbgramg_charge_payment_allocations IS
  'Current charge-level payment allocations. Legacy period-level allocations remain unchanged during migration.';
COMMENT ON COLUMN public.vbgramg_charge_payment_allocations.payment_id IS
  'References the original payment ledger entry; the payment ledger row is never duplicated.';
COMMENT ON COLUMN public.vbgramg_charge_payment_allocations.charge_id IS
  'References the exact contribution charge settled by this allocation.';
