-- Allow payment allocations from different sources to coexist for one payment/period.
-- Preserve existing rows; source-aware replacement and FIFO upsert remain atomic.

ALTER TABLE public.vbgramg_payment_allocations
  DROP CONSTRAINT IF EXISTS vbgramg_payment_allocations_transaction_id_period_id_key;

CREATE UNIQUE INDEX vbgramg_payment_allocations_transaction_period_source_key
  ON public.vbgramg_payment_allocations
  (transaction_id, period_id, allocation_source);

-- Keep automatic FIFO updates scoped to the fifo_auto row. Other sources are fixed.
DO $migration$
DECLARE
  v_definition text;
  v_original text;
BEGIN
  v_definition := pg_catalog.pg_get_functiondef(
    'public.vbgramg_auto_allocate_unallocated_payments(text)'::regprocedure
  );

  v_original := v_definition;
  v_definition := pg_catalog.replace(
    v_definition,
    'AND a.period_id = v_period.id;',
    'AND a.period_id = v_period.id
        AND a.allocation_source = ''fifo_auto'';'
  );
  IF v_definition = v_original THEN
    RAISE EXCEPTION 'Could not locate FIFO audit lookup to scope it to fifo_auto';
  END IF;

  v_original := v_definition;
  v_definition := pg_catalog.replace(
    v_definition,
    'ON CONFLICT (transaction_id, period_id) DO UPDATE',
    'ON CONFLICT (transaction_id, period_id, allocation_source) DO UPDATE'
  );
  IF v_definition = v_original THEN
    RAISE EXCEPTION 'Could not locate automatic FIFO conflict target';
  END IF;

  EXECUTE v_definition;
END;
$migration$;

-- Replacing one source must never delete allocations belonging to another source.
-- Payment capacity validation includes every retained source and refunds.
DO $migration$
DECLARE
  v_definition text;
  v_original text;
BEGIN
  v_definition := pg_catalog.pg_get_functiondef(
    'public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid)'::regprocedure
  );

  v_original := v_definition;
  v_definition := pg_catalog.replace(
    v_definition,
    'v_refunded numeric(12,2) := 0;',
    'v_refunded numeric(12,2) := 0;
  v_other_allocated numeric(12,2) := 0;'
  );
  IF v_definition = v_original THEN
    RAISE EXCEPTION 'Could not add retained-source allocation total';
  END IF;

  v_original := v_definition;
  v_definition := pg_catalog.replace(
    v_definition,
    'IF total + v_refunded > tx.amount THEN',
    'SELECT COALESCE(pg_catalog.sum(a.amount),0)::numeric(12,2)
    INTO v_other_allocated
  FROM public.vbgramg_payment_allocations a
  WHERE a.transaction_id = p_transaction_id
    AND a.allocation_source <> p_allocation_source;

  IF total + v_other_allocated + v_refunded > tx.amount THEN'
  );
  IF v_definition = v_original THEN
    RAISE EXCEPTION 'Could not locate payment capacity validation';
  END IF;

  v_original := v_definition;
  v_definition := pg_catalog.replace(
    v_definition,
    'DELETE FROM public.vbgramg_payment_allocations
  WHERE transaction_id = p_transaction_id;',
    'DELETE FROM public.vbgramg_payment_allocations
  WHERE transaction_id = p_transaction_id
    AND allocation_source = p_allocation_source;'
  );
  IF v_definition = v_original THEN
    RAISE EXCEPTION 'Could not locate source-wide allocation replacement delete';
  END IF;

  EXECUTE v_definition;
END;
$migration$;

COMMENT ON INDEX public.vbgramg_payment_allocations_transaction_period_source_key IS
  'Allows one payment allocation per period and allocation source; all sources remain jointly validated against payment capacity.';
