-- Record a bulk bank-payment batch and its audit trail atomically.
-- The Edge Function remains responsible for authentication and admin authorization.

CREATE OR REPLACE FUNCTION public.vbgramg_record_bulk_bank_payment(
  p_entries jsonb,
  p_entry_date date,
  p_actor_user_id uuid,
  p_actor_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $function$
DECLARE
  v_item jsonb;
  v_row record;
  v_job_card text;
  v_person_name text;
  v_amount numeric;
  v_entry public.vbgramg_charge_ledger%ROWTYPE;
  v_entry_json jsonb;
  v_entries jsonb := '[]'::jsonb;
  v_total numeric := 0;
  v_count integer;
  v_inserted integer := 0;
BEGIN
  IF p_entries IS NULL OR pg_catalog.jsonb_typeof(p_entries) IS DISTINCT FROM 'array' THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400,
      'error', 'A bulk payment batch must contain 1–500 entries.');
  END IF;

  IF pg_catalog.jsonb_array_length(p_entries) < 1
     OR pg_catalog.jsonb_array_length(p_entries) > 500 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400,
      'error', 'A bulk payment batch must contain 1–500 entries.');
  END IF;

  IF p_entry_date IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400,
      'error', 'Choose a valid payment date.');
  END IF;

  -- Validate the complete payload before taking locks or writing anything.
  FOR v_item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_entries)
  LOOP
    IF pg_catalog.jsonb_typeof(v_item) IS DISTINCT FROM 'object'
       OR pg_catalog.jsonb_typeof(v_item->'job_card_number') IS DISTINCT FROM 'string'
       OR pg_catalog.btrim(v_item->>'job_card_number') = ''
       OR pg_catalog.length(pg_catalog.btrim(v_item->>'job_card_number')) > 100
       OR pg_catalog.jsonb_typeof(v_item->'amount') IS DISTINCT FROM 'number' THEN
      RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400,
        'error', 'Every row must have a valid job card number and positive amount.');
    END IF;

    v_amount := (v_item->>'amount')::numeric;
    IF v_amount IS NULL OR v_amount <= 0 OR v_amount > 10000000
       OR v_amount::text IN ('NaN', 'Infinity', '-Infinity') THEN
      RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400,
        'error', 'Every row must have a valid job card number and positive amount.');
    END IF;
  END LOOP;

  SELECT pg_catalog.count(*)
    INTO v_count
  FROM (
    SELECT pg_catalog.btrim(value->>'job_card_number') AS job_card
    FROM pg_catalog.jsonb_array_elements(p_entries) AS t(value)
    GROUP BY pg_catalog.btrim(value->>'job_card_number')
    HAVING pg_catalog.count(*) > 1
  ) AS duplicates;

  IF v_count > 0 THEN
    SELECT pg_catalog.btrim(value->>'job_card_number')
      INTO v_job_card
    FROM pg_catalog.jsonb_array_elements(p_entries) AS t(value)
    GROUP BY pg_catalog.btrim(value->>'job_card_number')
    HAVING pg_catalog.count(*) > 1
    ORDER BY pg_catalog.btrim(value->>'job_card_number')
    LIMIT 1;
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400,
      'error', 'Duplicate job card in batch: ' || v_job_card);
  END IF;

  -- Use the same per-card lock key as single contribution transactions.
  -- Sorted acquisition prevents lock-order deadlocks for overlapping batches.
  FOR v_row IN
    SELECT DISTINCT pg_catalog.btrim(value->>'job_card_number') AS job_card
    FROM pg_catalog.jsonb_array_elements(p_entries) AS t(value)
    ORDER BY job_card
  LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('vbgramg-contribution:' || v_row.job_card, 0)
    );
  END LOOP;

  -- Validate every card before inserting any payment.
  FOR v_row IN
    SELECT pg_catalog.btrim(value->>'job_card_number') AS job_card,
           (value->>'amount')::numeric AS amount
    FROM pg_catalog.jsonb_array_elements(p_entries) AS t(value)
    ORDER BY pg_catalog.btrim(value->>'job_card_number')
  LOOP
    IF EXISTS (
      SELECT 1
      FROM public.vbgramg_contribution_exemptions AS e
      WHERE pg_catalog.btrim(e.job_card_number) = v_row.job_card
    ) THEN
      RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 409,
        'error', 'Job card ' || v_row.job_card || ' is exempted from contribution charges. No payments were recorded.');
    END IF;

    SELECT l.person_name
      INTO v_person_name
    FROM public.vbgramg_charge_ledger AS l
    WHERE l.job_card_number = v_row.job_card
      AND l.entry_type = 'charge'
    ORDER BY l.created_at ASC, l.id ASC
    LIMIT 1;

    IF NOT FOUND THEN
      RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400,
        'error', 'No existing contribution charge found for: ' || v_row.job_card || '. No payments were recorded.');
    END IF;
  END LOOP;

  -- Insert each payment and its audit row in this same transaction.
  FOR v_row IN
    SELECT pg_catalog.btrim(value->>'job_card_number') AS job_card,
           (value->>'amount')::numeric AS amount
    FROM pg_catalog.jsonb_array_elements(p_entries) WITH ORDINALITY AS t(value, ord)
    ORDER BY ord
  LOOP
    SELECT l.person_name
      INTO v_person_name
    FROM public.vbgramg_charge_ledger AS l
    WHERE l.job_card_number = v_row.job_card
      AND l.entry_type = 'charge'
    ORDER BY l.created_at ASC, l.id ASC
    LIMIT 1;

    INSERT INTO public.vbgramg_charge_ledger (
      job_card_number, person_name, entry_type, amount, entry_date, note, created_by
    ) VALUES (
      v_row.job_card, v_person_name, 'payment', v_row.amount, p_entry_date, 'Bank', p_actor_user_id
    )
    RETURNING * INTO v_entry;

    -- A BEFORE INSERT trigger can suppress a row by returning NULL. Treat that
    -- as a failure, never as a successful partial batch.
    IF NOT FOUND THEN
      RAISE EXCEPTION 'The contribution ledger rejected a bank payment for job card %.', v_row.job_card;
    END IF;

    v_entry_json := pg_catalog.jsonb_build_object(
      'id', v_entry.id,
      'job_card_number', v_entry.job_card_number,
      'person_name', v_entry.person_name,
      'entry_type', v_entry.entry_type,
      'amount', v_entry.amount,
      'charge_period', v_entry.charge_period,
      'entry_date', v_entry.entry_date,
      'note', v_entry.note,
      'created_at', v_entry.created_at,
      'is_deferred', v_entry.is_deferred,
      'source_created_at_ms', v_entry.source_created_at_ms,
      'legacy_entry_id', v_entry.legacy_entry_id
    );

    INSERT INTO public.vbgramg_ledger_audit (
      ledger_entry_id, job_card_number, action, actor_user_id, actor_email, before_data, after_data
    ) VALUES (
      v_entry.id,
      v_entry.job_card_number,
      'bulk-bank-payment',
      p_actor_user_id,
      pg_catalog.lower(pg_catalog.btrim(COALESCE(p_actor_email, ''))),
      NULL,
      v_entry_json
    );

    v_entries := v_entries || pg_catalog.jsonb_build_array(v_entry_json);
    v_total := v_total + v_row.amount;
    v_inserted := v_inserted + 1;
  END LOOP;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'entries', v_entries,
    'count', v_inserted,
    'total_amount', v_total,
    'method', 'Bank'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.vbgramg_record_bulk_bank_payment(jsonb, date, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vbgramg_record_bulk_bank_payment(jsonb, date, uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_record_bulk_bank_payment(jsonb, date, uuid, text) TO service_role;
