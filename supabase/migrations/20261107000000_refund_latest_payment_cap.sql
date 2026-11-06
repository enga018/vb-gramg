-- Atomic contribution writes. Generated migration filename by Supabase CLI.
-- Before promotion to a migration, validate it against an isolated PostgreSQL database

CREATE OR REPLACE FUNCTION public.vbgramg_record_contribution_transaction(
  p_job_card_number text,
  p_operation text,
  p_amount numeric,
  p_entry_date date,
  p_note text,
  p_actor_user_id uuid,
  p_actor_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $function$
DECLARE
  v_job_card text := pg_catalog.btrim(p_job_card_number);
  v_person_name text;
  v_charges numeric := 0;
  v_paid numeric := 0;
  v_returns numeric := 0;
  v_waived numeric := 0;
  v_balance numeric := 0;
  v_amount numeric;
  v_latest_payment numeric;
  v_entry_type text;
  v_final_note text;
  v_audit_action text;
  v_entry public.vbgramg_charge_ledger%ROWTYPE;
  v_entry_json jsonb;
  v_rows integer;
BEGIN
  IF v_job_card IS NULL OR v_job_card = '' OR pg_catalog.length(v_job_card) > 100 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400, 'error', 'A valid full job card number is required.');
  END IF;

  IF p_operation IS NULL OR p_operation NOT IN ('cash_payment', 'pay_in_full', 'waiver', 'return') THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400, 'error', 'Unsupported contribution transaction operation.');
  END IF;

  IF p_entry_date IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400, 'error', 'Enter a valid transaction date.');
  END IF;

  IF p_operation <> 'pay_in_full' AND (p_amount IS NULL OR p_amount <= 0) THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400, 'error', 'Enter a valid positive amount.');
  END IF;

  IF p_operation = 'cash_payment' AND p_amount > 10000000 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400, 'error', 'Enter a valid job card number and positive payment amount.');
  END IF;

  -- Serialize all four transaction types for the same normalized job card.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-contribution:' || v_job_card, 0)
  );

  -- The existing BEFORE INSERT trigger returns NULL for exempt cards. Reject
  -- explicitly here so callers never mistake a skipped insert for success.
  IF EXISTS (
    SELECT 1
    FROM public.vbgramg_contribution_exemptions AS e
    WHERE pg_catalog.btrim(e.job_card_number) = v_job_card
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 409, 'error', 'This job card is exempted from contribution charges.');
  END IF;

  IF p_operation = 'cash_payment' THEN
    -- Cash payment specifically requires an existing charge row, matching add-payment.
    SELECT l.person_name
      INTO v_person_name
    FROM public.vbgramg_charge_ledger AS l
    WHERE l.job_card_number = v_job_card
      AND l.entry_type = 'charge'
    ORDER BY l.created_at ASC, l.id ASC
    LIMIT 1;
  ELSE
    -- Waiver, return, and pay-in-full historically require a ledger record,
    -- but only cash payment has the stricter existing-charge requirement.
    SELECT l.person_name
      INTO v_person_name
    FROM public.vbgramg_charge_ledger AS l
    WHERE l.job_card_number = v_job_card
    ORDER BY l.created_at ASC, l.id ASC
    LIMIT 1;
  END IF;

  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 404, 'error', 'Job card not found in the contribution ledger.');
  END IF;

  -- Keep the shared JavaScript ledger semantics exactly:
  -- * voided rows are ignored;
  -- * deferred charges do not affect outstanding balance;
  -- * legacy charge rows whose trimmed note is exactly "Return" are returns;
  -- * legacy return/forgive/sanitationFee values remain recognized.
  SELECT
    COALESCE(pg_catalog.sum(GREATEST(COALESCE(l.amount, 0), 0))
      FILTER (WHERE l.entry_type IN ('charge', 'other_charge', 'sanitationFee')
        AND NOT COALESCE(l.is_deferred, false)
        AND NOT (l.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(l.note, '')) = 'Return')), 0),
    COALESCE(pg_catalog.sum(GREATEST(COALESCE(l.amount, 0), 0))
      FILTER (WHERE l.entry_type = 'payment'), 0),
    COALESCE(pg_catalog.sum(GREATEST(COALESCE(l.amount, 0), 0))
      FILTER (WHERE l.entry_type IN ('refund', 'return')
        OR (l.entry_type = 'charge' AND pg_catalog.btrim(COALESCE(l.note, '')) = 'Return')), 0),
    COALESCE(pg_catalog.sum(GREATEST(COALESCE(l.amount, 0), 0))
      FILTER (WHERE l.entry_type IN ('charge_waiver', 'forgive')), 0)
  INTO v_charges, v_paid, v_returns, v_waived
  FROM public.vbgramg_charge_ledger AS l
  WHERE l.job_card_number = v_job_card
    AND NOT COALESCE(l.is_voided, false);

  v_balance := GREATEST(v_charges - LEAST(v_charges, v_waived), 0) - v_paid + v_returns;

  v_amount := p_amount;
  v_final_note := COALESCE(pg_catalog.left(pg_catalog.btrim(p_note), 200), '');
  IF p_operation IN ('cash_payment', 'pay_in_full') THEN
    v_final_note := 'Cash';
  END IF;

  CASE p_operation
    WHEN 'cash_payment' THEN
      v_entry_type := 'payment';
      v_audit_action := 'cash-payment';
      v_final_note := 'Cash';
    WHEN 'pay_in_full' THEN
      v_amount := GREATEST(0, pg_catalog.round(v_balance, 2));
      v_entry_type := 'payment';
      v_audit_action := 'pay-in-full';
      v_final_note := 'Cash';
    WHEN 'waiver' THEN
      v_entry_type := 'charge_waiver';
      v_audit_action := 'waiver';
      IF v_amount > GREATEST(0, v_balance) + 0.001 THEN
        RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400, 'error', 'Waiver must be positive and cannot exceed the current outstanding balance.');
      END IF;
    WHEN 'return' THEN
      v_entry_type := 'refund';
      v_audit_action := 'return';
      -- Each refund is capped independently at the latest active payment.
      -- Earlier refunds do not reduce this per-transaction cap.
      SELECT GREATEST(COALESCE(l.amount, 0), 0)
        INTO v_latest_payment
      FROM public.vbgramg_charge_ledger AS l
      WHERE l.job_card_number = v_job_card
        AND l.entry_type = 'payment'
        AND NOT COALESCE(l.is_voided, false)
      ORDER BY l.created_at DESC, l.id DESC
      LIMIT 1;

      IF NOT FOUND OR v_latest_payment IS NULL OR v_latest_payment <= 0 THEN
        RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400, 'error', 'A refund requires a recorded active payment for this job card.');
      END IF;

      IF v_amount > v_latest_payment THEN
        RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 400, 'error', 'Refund cannot exceed the latest active payment amount.');
      END IF;
  END CASE;

  IF v_amount IS NULL OR v_amount <= 0 THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok', false,
      'status', 400,
      'error', CASE WHEN p_operation = 'pay_in_full'
        THEN 'There is no outstanding balance to pay in full.'
        ELSE 'Enter a valid positive amount.'
      END
    );
  END IF;

  INSERT INTO public.vbgramg_charge_ledger (
    job_card_number, person_name, entry_type, amount, entry_date, note, created_by
  ) VALUES (
    v_job_card, v_person_name, v_entry_type, v_amount, p_entry_date, v_final_note, p_actor_user_id
  )
  RETURNING * INTO v_entry;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows <> 1 THEN
    RETURN pg_catalog.jsonb_build_object('ok', false, 'status', 409, 'error', 'The contribution ledger did not accept this transaction. No transaction was recorded.');
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

  -- Preserve current behaviour: ordinary cash payments do not create audit rows.
  -- The other three admin/special operations keep their existing audit records.
  IF p_operation <> 'cash_payment' THEN
    INSERT INTO public.vbgramg_ledger_audit (
      ledger_entry_id, job_card_number, action, actor_user_id, actor_email, before_data, after_data
    ) VALUES (
      v_entry.id,
      v_job_card,
      v_audit_action,
      p_actor_user_id,
      pg_catalog.lower(pg_catalog.btrim(COALESCE(p_actor_email, ''))),
      pg_catalog.jsonb_build_object('balance', v_balance),
      v_entry_json
    );
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'ok', true,
    'entry', v_entry_json,
    'balance_before', v_balance,
    'balance_after', CASE p_operation
      WHEN 'cash_payment' THEN v_balance - v_amount
      WHEN 'pay_in_full' THEN v_balance - v_amount
      WHEN 'waiver' THEN v_balance - v_amount
      ELSE v_balance + v_amount
    END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.vbgramg_record_contribution_transaction(text, text, numeric, date, text, uuid, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vbgramg_record_contribution_transaction(text, text, numeric, date, text, uuid, text) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_record_contribution_transaction(text, text, numeric, date, text, uuid, text) TO service_role;
