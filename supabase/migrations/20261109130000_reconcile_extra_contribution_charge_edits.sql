-- Reconcile period payment allocations whenever an Extra Contribution charge is edited.
-- Keep this workflow atomic: linked extra row, ledger charge, allocation releases, and audit
-- records all commit or roll back together.

CREATE OR REPLACE FUNCTION public.vbgramg_save_contribution_extra(
  p_job_card_number text, p_charge_period date, p_period_id uuid,
  p_amount numeric, p_reason text, p_entry_date date, p_actor_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO ''
AS $$
DECLARE
  v_card text := pg_catalog.btrim(COALESCE(p_job_card_number,''));
  v_reason text := pg_catalog.btrim(COALESCE(p_reason,''));
  v_round public.vbgramg_periods%ROWTYPE;
  v_old public.vbgramg_contribution_extras%ROWTYPE;
  v_entry public.vbgramg_charge_ledger%ROWTYPE;
  v_entry_before public.vbgramg_charge_ledger%ROWTYPE;
  v_extra public.vbgramg_contribution_extras%ROWTYPE;
  v_name text;
  v_note text;
  v_updated boolean := false;
  v_rows integer;
  v_eligible_charges numeric(14,2) := 0;
  v_period_waived numeric(14,2) := 0;
  v_allocated_total numeric(14,2) := 0;
  v_excess_to_release numeric(14,2) := 0;
  v_release_amount numeric(14,2) := 0;
  v_remaining_amount numeric(14,2) := 0;
  v_released_total numeric(14,2) := 0;
  v_release_count integer := 0;
  v_payment record;
  v_allocation public.vbgramg_payment_allocations%ROWTYPE;
  v_released_allocations jsonb := '[]'::jsonb;
BEGIN
  IF v_card='' OR pg_catalog.length(v_card)>100 THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Choose a job card.');
  END IF;
  IF p_charge_period IS NULL OR EXTRACT(day FROM p_charge_period)<>1 THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Choose a valid contribution month.');
  END IF;
  IF p_period_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Select a specific contribution round.');
  END IF;
  IF p_amount IS NULL OR p_amount<=0 OR p_amount>10000000
     OR p_amount::text IN ('NaN','Infinity','-Infinity') THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Enter an extra amount greater than zero.');
  END IF;
  IF v_reason='' THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Enter a reason for the extra amount.');
  END IF;
  IF p_entry_date IS NULL OR p_actor_user_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','The extra charge date or actor is missing.');
  END IF;
  v_reason := pg_catalog.left(v_reason,500);

  -- Match the global household-then-period lock order used by contribution writes.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-contribution:'||v_card,0)
  );
  IF EXISTS (SELECT 1 FROM public.vbgramg_contribution_exemptions e
             WHERE pg_catalog.btrim(e.job_card_number)=v_card) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,
      'error','Job card '||v_card||' is exempted from contribution charges.');
  END IF;

  SELECT * INTO v_round FROM public.vbgramg_periods
  WHERE id=p_period_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',404,'error','The selected contribution round was not found.');
  END IF;
  IF COALESCE(v_round.status,'open')<>'open' THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,
      'error','This contribution round is closed. Reopen it before changing its extra charge.');
  END IF;
  IF COALESCE(v_round.contribution_month,v_round.period_date) IS NULL
     OR pg_catalog.date_trunc('month',COALESCE(v_round.contribution_month,v_round.period_date))::date<>p_charge_period THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,
      'error','The selected contribution round does not match the chosen month.');
  END IF;

  SELECT l.person_name INTO v_name FROM public.vbgramg_charge_ledger l
  WHERE l.job_card_number=v_card ORDER BY l.created_at,l.id LIMIT 1;
  IF v_name IS NULL OR pg_catalog.btrim(v_name)='' THEN
    SELECT c.person_name INTO v_name FROM public.vbgramg_contribution_citizens c
    WHERE c.job_card_number=v_card LIMIT 1;
  END IF;
  IF v_name IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',404,
      'error','This job card is not present in the contribution records.');
  END IF;
  v_name := COALESCE(NULLIF(pg_catalog.btrim(v_name),''),v_card);

  SELECT * INTO v_old FROM public.vbgramg_contribution_extras
  WHERE job_card_number=v_card AND period_id=p_period_id FOR UPDATE;
  v_updated := FOUND;
  v_note := pg_catalog.left('FTO EXTRA: '||v_reason,200);

  IF v_updated AND v_old.ledger_entry_id IS NOT NULL THEN
    -- Updates must serialize against allocations for this specific round. New
    -- inserts leave period locking to the existing multi-period FIFO allocator.
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('contribution:'||v_card||':'||p_period_id::text,0)
    );
    SELECT * INTO v_entry FROM public.vbgramg_charge_ledger
    WHERE id=v_old.ledger_entry_id FOR UPDATE;
    IF FOUND THEN
      IF v_entry.job_card_number<>v_card OR v_entry.entry_type<>'charge'
         OR COALESCE(v_entry.is_voided,false) THEN
        RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,
          'error','The existing extra charge is linked to an incompatible ledger entry. No changes were made.');
      END IF;
      v_entry_before := v_entry;
      UPDATE public.vbgramg_charge_ledger
      SET person_name=v_name,amount=p_amount,entry_date=p_entry_date,note=v_note,
          charge_period=p_charge_period,period_id=p_period_id,is_deferred=false
      WHERE id=v_entry.id RETURNING * INTO v_entry;
      GET DIAGNOSTICS v_rows=ROW_COUNT;
      IF v_rows<>1 THEN RAISE EXCEPTION 'The contribution ledger rejected the extra charge update for job card %.',v_card; END IF;

      -- A reduction can make existing period allocations exceed the new eligible
      -- balance. Waivers also consume the period ceiling, so subtract them here.
      SELECT COALESCE(pg_catalog.sum(c.amount),0)::numeric(14,2)
        INTO v_eligible_charges
      FROM public.vbgramg_charge_ledger c
      WHERE c.job_card_number=v_card AND c.period_id=p_period_id
        AND c.entry_type IN ('charge','other_charge','sanitationFee')
        AND COALESCE(c.is_deferred,false)=false
        AND COALESCE(c.is_voided,false)=false
        AND NOT (c.entry_type='charge' AND pg_catalog.btrim(COALESCE(c.note,''))='Return');

      SELECT COALESCE(pg_catalog.sum(w.amount),0)::numeric(14,2)
        INTO v_period_waived
      FROM public.vbgramg_waiver_period_allocations w
      JOIN public.vbgramg_charge_ledger waiver ON waiver.id=w.waiver_id
      WHERE w.job_card_number=v_card AND w.period_id=p_period_id
        AND waiver.entry_type IN ('charge_waiver','forgive')
        AND COALESCE(waiver.is_voided,false)=false;

      v_eligible_charges := GREATEST(v_eligible_charges-v_period_waived,0);

      SELECT COALESCE(pg_catalog.sum(a.amount),0)::numeric(14,2)
        INTO v_allocated_total
      FROM public.vbgramg_payment_allocations a
      JOIN public.vbgramg_charge_ledger payment ON payment.id=a.transaction_id
      WHERE a.job_card_number=v_card AND a.period_id=p_period_id
        AND payment.entry_type='payment'
        AND COALESCE(payment.is_voided,false)=false;

      v_excess_to_release := GREATEST(v_allocated_total-v_eligible_charges,0);

      IF v_excess_to_release>0.001 THEN
        -- Lock payment rows before allocation rows, matching the manual allocator's
        -- period -> payment -> allocation order and avoiding lock-order inversions.
        FOR v_payment IN
          SELECT payment.id
          FROM public.vbgramg_charge_ledger payment
          WHERE payment.id IN (
            SELECT a.transaction_id
            FROM public.vbgramg_payment_allocations a
            WHERE a.job_card_number=v_card AND a.period_id=p_period_id
          )
            AND payment.entry_type='payment'
            AND COALESCE(payment.is_voided,false)=false
          ORDER BY payment.id
          FOR UPDATE
        LOOP
          NULL;
        END LOOP;

        -- Preserve the oldest allocations. Release the newest first, and only
        -- release the exact excess; partial reductions retain the FIFO remainder.
        FOR v_allocation IN
          SELECT a.*
          FROM public.vbgramg_payment_allocations a
          JOIN public.vbgramg_charge_ledger payment ON payment.id=a.transaction_id
          WHERE a.job_card_number=v_card AND a.period_id=p_period_id
            AND payment.entry_type='payment'
            AND COALESCE(payment.is_voided,false)=false
          ORDER BY a.created_at DESC,a.id DESC
          FOR UPDATE OF a
        LOOP
          EXIT WHEN v_excess_to_release<=0.001;
          v_release_amount := LEAST(v_allocation.amount,v_excess_to_release);
          v_remaining_amount := v_allocation.amount-v_release_amount;

          IF v_remaining_amount<=0.001 THEN
            DELETE FROM public.vbgramg_payment_allocations WHERE id=v_allocation.id;
            v_remaining_amount := 0;
          ELSE
            UPDATE public.vbgramg_payment_allocations
            SET amount=v_remaining_amount,updated_at=pg_catalog.now()
            WHERE id=v_allocation.id;
          END IF;

          INSERT INTO public.vbgramg_ledger_audit
            (ledger_entry_id,job_card_number,action,actor_user_id,before_data,after_data)
          VALUES
            (v_allocation.transaction_id,v_card,'payment_allocation_released_due_to_extra_charge_edit',
             p_actor_user_id,pg_catalog.to_jsonb(v_allocation),
             pg_catalog.jsonb_build_object(
               'allocation_id',v_allocation.id,'period_id',p_period_id,
               'payment_transaction_id',v_allocation.transaction_id,
               'previous_amount',v_allocation.amount,'remaining_amount',v_remaining_amount,
               'released_amount',v_release_amount,'reason','extra_charge_reduced',
               'extra_charge_id',v_entry.id,'eligible_period_balance_after_waivers',v_eligible_charges));

          v_released_allocations := v_released_allocations || pg_catalog.jsonb_build_array(
            pg_catalog.jsonb_build_object(
              'allocation_id',v_allocation.id,'transaction_id',v_allocation.transaction_id,
              'released_amount',v_release_amount,'remaining_amount',v_remaining_amount));
          v_excess_to_release := v_excess_to_release-v_release_amount;
          v_released_total := v_released_total+v_release_amount;
          v_release_count := v_release_count+1;
        END LOOP;

        IF v_excess_to_release>0.001 THEN
          RAISE EXCEPTION 'Could not reconcile the excess period payment allocations for job card %.',v_card
            USING ERRCODE='23514';
        END IF;
      END IF;
    END IF;
  END IF;

  IF v_entry.id IS NULL THEN
    INSERT INTO public.vbgramg_charge_ledger
      (job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note,is_deferred,created_by)
    VALUES (v_card,v_name,'charge',p_amount,p_charge_period,p_period_id,p_entry_date,v_note,false,p_actor_user_id)
    RETURNING * INTO v_entry;
    GET DIAGNOSTICS v_rows=ROW_COUNT;
    IF v_rows<>1 THEN RAISE EXCEPTION 'The contribution ledger rejected the extra charge for job card %.',v_card; END IF;
  END IF;

  INSERT INTO public.vbgramg_contribution_extras
    (job_card_number,person_name,charge_period,period_id,amount,reason,ledger_entry_id,created_by,updated_by,updated_at)
  VALUES
    (v_card,v_name,p_charge_period,p_period_id,p_amount,v_reason,v_entry.id,
     CASE WHEN v_updated THEN COALESCE(v_old.created_by,p_actor_user_id) ELSE p_actor_user_id END,p_actor_user_id,pg_catalog.now())
  ON CONFLICT (job_card_number,period_id) DO UPDATE
  SET person_name=EXCLUDED.person_name,charge_period=EXCLUDED.charge_period,
      amount=EXCLUDED.amount,reason=EXCLUDED.reason,ledger_entry_id=EXCLUDED.ledger_entry_id,
      updated_by=EXCLUDED.updated_by,updated_at=EXCLUDED.updated_at
  RETURNING * INTO v_extra;

  IF v_updated AND v_entry_before.id IS NOT NULL THEN
    INSERT INTO public.vbgramg_ledger_audit
      (ledger_entry_id,job_card_number,action,actor_user_id,before_data,after_data)
    VALUES
      (v_entry.id,v_card,'extra_contribution_charge_edit',p_actor_user_id,
       pg_catalog.jsonb_build_object('extra',pg_catalog.to_jsonb(v_old),'ledger_entry',pg_catalog.to_jsonb(v_entry_before)),
       pg_catalog.jsonb_build_object('extra',pg_catalog.to_jsonb(v_extra),'ledger_entry',pg_catalog.to_jsonb(v_entry),
         'released_allocations',v_released_allocations,'released_total',v_released_total));
  END IF;

  RETURN pg_catalog.jsonb_build_object(
    'ok',true,'updated',v_updated,
    'released_allocation_amount',v_released_total,
    'released_allocation_count',v_release_count,
    'entry',pg_catalog.jsonb_build_object(
      'id',v_entry.id,'job_card_number',v_entry.job_card_number,'person_name',v_entry.person_name,
      'entry_type',v_entry.entry_type,'amount',v_entry.amount,'charge_period',v_entry.charge_period,
      'period_id',v_entry.period_id,'entry_date',v_entry.entry_date,'note',v_entry.note,
      'created_at',v_entry.created_at,'is_deferred',v_entry.is_deferred,
      'source_created_at_ms',v_entry.source_created_at_ms,'legacy_entry_id',v_entry.legacy_entry_id),
    'extra',pg_catalog.jsonb_build_object(
      'id',v_extra.id,'job_card_number',v_extra.job_card_number,'person_name',v_extra.person_name,
      'charge_period',v_extra.charge_period,'period_id',v_extra.period_id,'amount',v_extra.amount,
      'reason',v_extra.reason,'ledger_entry_id',v_extra.ledger_entry_id,
      'created_at',v_extra.created_at,'updated_at',v_extra.updated_at)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.vbgramg_save_contribution_extra(text,date,uuid,numeric,text,date,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vbgramg_save_contribution_extra(text,date,uuid,numeric,text,date,uuid) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_save_contribution_extra(text,date,uuid,numeric,text,date,uuid) TO service_role;
