-- Harden the authoritative FIFO read and payment-allocation replacement path.
-- Match the payment_ids CTE across SQL formatter whitespace without depending
-- on whether SELECT/FROM/WHERE are emitted on one line or several.
DO $migration$
DECLARE
  v_fifo text;
  v_fifo_before text;
  v_replace text;
  v_replace_before text;
  v_fifo_pattern text := 'payment_ids AS \([[:space:]]*SELECT[[:space:]]+id[[:space:]]+FROM[[:space:]]+card_ledger[[:space:]]+WHERE[[:space:]]+entry_type[[:space:]]*=[[:space:]]*''payment''[[:space:]]*\)';
  v_fifo_replacement text := 'payment_ids AS (
    SELECT id
    FROM card_ledger
    WHERE entry_type = ''payment''
      AND NOT COALESCE(is_voided, false)
  )';
  v_replace_pattern text := 'IF NOT FOUND OR tx\.entry_type <> ''payment'' OR tx\.job_card_number IS DISTINCT FROM v_card THEN[[:space:]]+RAISE EXCEPTION ''Valid payment transaction required'';[[:space:]]+END IF;';
  v_replace_replacement text := 'IF NOT FOUND OR tx.entry_type <> ''payment''
       OR tx.job_card_number IS DISTINCT FROM v_card
       OR COALESCE(tx.is_voided, false) THEN
      RAISE EXCEPTION ''Valid active payment transaction required'';
  END IF;';
BEGIN
  v_fifo := pg_catalog.pg_get_functiondef(
    'public.vbgramg_contribution_fifo_breakdown(text)'::regprocedure
  );
  v_fifo_before := v_fifo;
  v_fifo := pg_catalog.regexp_replace(v_fifo, v_fifo_pattern, v_fifo_replacement, 'g');
  IF v_fifo = v_fifo_before THEN
    RAISE EXCEPTION 'Expected payment_ids predicate not found in FIFO function; aborting migration';
  END IF;
  IF pg_catalog.strpos(v_fifo, 'AND NOT COALESCE(is_voided, false)') = 0 THEN
    RAISE EXCEPTION 'Voided-payment filter was not applied to FIFO function';
  END IF;
  EXECUTE v_fifo;

  v_replace := pg_catalog.pg_get_functiondef(
    'public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid)'::regprocedure
  );
  v_replace_before := v_replace;
  v_replace := pg_catalog.regexp_replace(v_replace, v_replace_pattern, v_replace_replacement, 'g');
  IF v_replace = v_replace_before THEN
    RAISE EXCEPTION 'Expected payment validation predicate not found; aborting migration';
  END IF;
  IF pg_catalog.strpos(v_replace, 'OR COALESCE(tx.is_voided, false)') = 0 THEN
    RAISE EXCEPTION 'Active-payment guard was not applied to replacement RPC';
  END IF;
  EXECUTE v_replace;
END;
$migration$;
