-- Harden the authoritative FIFO read and payment-allocation replacement path.
-- Preserve the existing function bodies and change only the guarded predicates.
DO $migration$
DECLARE
  v_fifo text;
  v_replace text;
  v_old_fifo text := $old$
payment_ids AS (
  SELECT id
  FROM card_ledger
  WHERE entry_type = 'payment'
),
$old$;
  v_new_fifo text := $new$
payment_ids AS (
  SELECT id
  FROM card_ledger
  WHERE entry_type = 'payment'
    AND NOT COALESCE(is_voided, false)
),
$new$;
  v_old_replace text := $old$
IF NOT FOUND OR tx.entry_type <> 'payment' OR tx.job_card_number IS DISTINCT FROM v_card THEN
    RAISE EXCEPTION 'Valid payment transaction required';
  END IF;
$old$;
  v_new_replace text := $new$
IF NOT FOUND OR tx.entry_type <> 'payment'
     OR tx.job_card_number IS DISTINCT FROM v_card
     OR COALESCE(tx.is_voided, false) THEN
    RAISE EXCEPTION 'Valid active payment transaction required';
  END IF;
$new$;
BEGIN
  v_fifo := pg_catalog.pg_get_functiondef(
    'public.vbgramg_contribution_fifo_breakdown(text)'::regprocedure
  );
  IF pg_catalog.strpos(v_fifo, v_old_fifo) = 0 THEN
    RAISE EXCEPTION 'Expected payment_ids predicate not found in FIFO function; aborting migration';
  END IF;
  v_fifo := pg_catalog.replace(v_fifo, v_old_fifo, v_new_fifo);
  IF pg_catalog.strpos(v_fifo, v_new_fifo) = 0 THEN
    RAISE EXCEPTION 'Voided-payment filter was not applied to FIFO function';
  END IF;
  EXECUTE v_fifo;

  v_replace := pg_catalog.pg_get_functiondef(
    'public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid)'::regprocedure
  );
  IF pg_catalog.strpos(v_replace, v_old_replace) = 0 THEN
    RAISE EXCEPTION 'Expected payment validation predicate not found; aborting migration';
  END IF;
  v_replace := pg_catalog.replace(v_replace, v_old_replace, v_new_replace);
  IF pg_catalog.strpos(v_replace, v_new_replace) = 0 THEN
    RAISE EXCEPTION 'Active-payment guard was not applied to replacement RPC';
  END IF;
  EXECUTE v_replace;
END;
$migration$;
