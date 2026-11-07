-- Atomic generic ledger editing with allocation/refund reconciliation safeguards.
-- The Edge Function remains the authenticated entry point; this SECURITY DEFINER RPC
-- performs the ledger update, linked reconciliation update, and audit insert atomically.

CREATE OR REPLACE FUNCTION public.vbgramg_edit_contribution_ledger_entry(
  p_id uuid,
  p_amount numeric,
  p_entry_date date,
  p_note text,
  p_charge_period date,
  p_is_deferred boolean,
  p_actor_user_id uuid,
  p_actor_email text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $$
DECLARE
  v_old public.vbgramg_charge_ledger%ROWTYPE;
  v_updated public.vbgramg_charge_ledger%ROWTYPE;
  v_type text;
  v_is_legacy_return boolean;
  v_note text := pg_catalog.left(pg_catalog.btrim(COALESCE(p_note,'')),200);
  v_charge_period date;
  v_allocated numeric(14,2) := 0;
  v_refunded numeric(14,2) := 0;
  v_eligible numeric(14,2) := 0;
  v_refund_count integer := 0;
  v_refund_reconciliations_before jsonb := '[]'::jsonb;
  v_refund_reconciliations_after jsonb := '[]'::jsonb;
BEGIN
  IF p_id IS NULL OR p_actor_user_id IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Ledger entry and administrator are required.');
  END IF;
  IF p_amount IS NULL OR p_amount<=0 OR p_amount>10000000
     OR p_amount::text IN ('NaN','Infinity','-Infinity') THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Enter a valid positive amount.');
  END IF;
  IF p_entry_date IS NULL THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Enter a valid transaction date.');
  END IF;

  SELECT * INTO v_old
  FROM public.vbgramg_charge_ledger
  WHERE id=p_id;

  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',404,'error','Ledger entry was not found.');
  END IF;

  -- Acquire the household lock before row locks, matching the contribution/FTO
  -- write paths and avoiding lock-order inversions.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-contribution:'||v_old.job_card_number,0)
  );

  SELECT * INTO v_old
  FROM public.vbgramg_charge_ledger
  WHERE id=p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',404,'error','Ledger entry was not found.');
  END IF;
  IF COALESCE(v_old.is_voided,false) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','This charge was removed from the current FTO snapshot and cannot be edited.');
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.vbgramg_contribution_exemptions e
    WHERE pg_catalog.btrim(e.job_card_number)=pg_catalog.btrim(v_old.job_card_number)
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','This job card is exempted. Its ledger entries cannot be edited.');
  END IF;

  v_type := COALESCE(v_old.entry_type,'');
  v_is_legacy_return := v_type='charge'
    AND pg_catalog.lower(pg_catalog.btrim(COALESCE(v_old.note,'')))='return';

  IF v_type NOT IN ('charge','payment','refund','charge_waiver','other_charge','return','forgive','sanitationFee') THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','This transaction type cannot be edited here.');
  END IF;

  -- Extra contribution charges are maintained with their dedicated atomic RPC,
  -- which also updates vbgramg_contribution_extras.
  IF v_type='charge' AND (
    pg_catalog.upper(pg_catalog.left(COALESCE(v_old.note,''),9))='FTO EXTRA'
    OR EXISTS (SELECT 1 FROM public.vbgramg_contribution_extras x WHERE x.ledger_entry_id=v_old.id)
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','Edit this extra charge through the Extra Contribution form so its linked record stays synchronized.');
  END IF;

  -- FTO-imported charges must be revised through the dedicated FTO workflow.
  -- Generic ledger edits cannot safely update the source FTO batch and its snapshot.
  IF v_type='charge' AND NOT v_is_legacy_return
     AND pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(COALESCE(v_old.note,'')),3))='FTO' THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok',false,'status',409,
      'error','FTO-imported charges cannot be edited here. Use the dedicated FTO Revise workflow so the FTO batch and contribution ledger stay synchronized.'
    );
  END IF;
  IF v_is_legacy_return AND pg_catalog.lower(v_note)<>'return' THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Keep the note as Return for this legacy entry.');
  END IF;

  v_charge_period := v_old.charge_period;
  IF v_type='charge' AND NOT v_is_legacy_return THEN
    v_charge_period := p_charge_period;
    IF v_charge_period IS NULL OR EXTRACT(day FROM v_charge_period)<>1 THEN
      RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Choose a valid charge month.');
    END IF;
    IF v_old.period_id IS NOT NULL AND v_charge_period IS DISTINCT FROM v_old.charge_period THEN
      RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','This charge belongs to a specific contribution round. Change its round through the FTO period reassignment workflow, not by editing the month here.');
    END IF;
    IF pg_catalog.upper(pg_catalog.left(COALESCE(v_old.note,''),3))='FTO'
       AND v_charge_period IS DISTINCT FROM v_old.charge_period THEN
      RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','FTO-imported charges must be reassigned through the FTO period workflow so the batch and ledger remain synchronized.');
    END IF;
  END IF;

  IF v_type='payment' THEN
    SELECT COALESCE(sum(a.amount),0)::numeric(14,2)
      INTO v_allocated
    FROM public.vbgramg_payment_allocations a
    WHERE a.transaction_id=v_old.id;

    SELECT COALESCE(sum(r.amount),0)::numeric(14,2)
      INTO v_refunded
    FROM public.vbgramg_payment_refund_reconciliations r
    WHERE r.payment_id=v_old.id;

    IF v_allocated+v_refunded>p_amount+0.001 THEN
      RETURN pg_catalog.jsonb_build_object(
        'ok',false,'status',409,
        'error','This payment has '||pg_catalog.to_char(v_allocated,'FM999999990.00')||
          ' allocated and '||pg_catalog.to_char(v_refunded,'FM999999990.00')||
          ' reconciled as refunds. The revised payment cannot be lower than their combined total.'
      );
    END IF;
  END IF;

  -- Legacy charges without period_id cannot be attributed safely when a month has
  -- multiple contribution rounds. If allocations exist in either affected month,
  -- require the administrator to resolve the period link before changing its balance.
  IF v_type='charge' AND NOT v_is_legacy_return AND v_old.period_id IS NULL
     AND (p_amount IS DISTINCT FROM v_old.amount
       OR COALESCE(p_is_deferred,false) IS DISTINCT FROM COALESCE(v_old.is_deferred,false)
       OR v_charge_period IS DISTINCT FROM v_old.charge_period)
     AND EXISTS (
       SELECT 1
       FROM public.vbgramg_payment_allocations a
       JOIN public.vbgramg_periods p ON p.id=a.period_id
       WHERE a.job_card_number=v_old.job_card_number
         AND pg_catalog.date_trunc('month',COALESCE(p.contribution_month,p.period_date))::date
             IN (v_old.charge_period,v_charge_period)
     ) THEN
    RETURN pg_catalog.jsonb_build_object(
      'ok',false,'status',409,
      'error','This legacy charge is not linked to a specific contribution round, but payments are already allocated in the same month. Resolve its period link before changing its amount, deferred status, or month.'
    );
  END IF;

  -- A period charge cannot be reduced below amounts already allocated to that round.
  -- Deferred and voided charges do not contribute to the eligible charge ceiling.
  IF v_type IN ('charge','other_charge') AND NOT v_is_legacy_return AND v_old.period_id IS NOT NULL THEN
    SELECT COALESCE(sum(a.amount),0)::numeric(14,2)
      INTO v_allocated
    FROM public.vbgramg_payment_allocations a
    WHERE a.job_card_number=v_old.job_card_number
      AND a.period_id=v_old.period_id;

    SELECT (
      COALESCE(sum(l.amount),0)
      + CASE WHEN (CASE WHEN v_type='charge' THEN COALESCE(p_is_deferred,false) ELSE COALESCE(v_old.is_deferred,false) END)=false THEN p_amount ELSE 0 END
    )::numeric(14,2)
      INTO v_eligible
    FROM public.vbgramg_charge_ledger l
    WHERE l.job_card_number=v_old.job_card_number
      AND l.period_id=v_old.period_id
      AND l.id<>v_old.id
      AND l.entry_type IN ('charge','other_charge')
      AND COALESCE(l.is_deferred,false)=false
      AND COALESCE(l.is_voided,false)=false;

    IF v_allocated>v_eligible+0.001 THEN
      RETURN pg_catalog.jsonb_build_object(
        'ok',false,'status',409,
        'error','This change would leave '||pg_catalog.to_char(v_allocated,'FM999999990.00')||
          ' allocated against only '||pg_catalog.to_char(v_eligible,'FM999999990.00')||
          ' eligible charges in this contribution round. Review the allocations first.'
      );
    END IF;
  END IF;

  UPDATE public.vbgramg_charge_ledger
  SET amount=p_amount,
      entry_date=p_entry_date,
      note=NULLIF(v_note,''),
      charge_period=CASE WHEN v_type='charge' AND NOT v_is_legacy_return THEN v_charge_period ELSE charge_period END,
      is_deferred=CASE WHEN v_type='charge' AND NOT v_is_legacy_return THEN COALESCE(p_is_deferred,false) ELSE is_deferred END
  WHERE id=v_old.id
  RETURNING * INTO v_updated;

  -- The reconciliation trigger validates against the current refund ledger amount,
  -- so update the ledger first, then synchronize its one-to-one refund match.
  IF v_type IN ('refund','return') THEN
    SELECT count(*)::integer,COALESCE(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r)),'[]'::jsonb)
      INTO v_refund_count,v_refund_reconciliations_before
    FROM public.vbgramg_payment_refund_reconciliations r
    WHERE r.refund_id=v_old.id;

    IF v_refund_count>1 THEN
      RAISE EXCEPTION 'Refund % has multiple payment reconciliations. Review its links before editing.',v_old.id
        USING ERRCODE='23514';
    ELSIF v_refund_count=1 THEN
      UPDATE public.vbgramg_payment_refund_reconciliations
      SET amount=p_amount
      WHERE refund_id=v_old.id;
      SELECT COALESCE(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r)),'[]'::jsonb)
        INTO v_refund_reconciliations_after
      FROM public.vbgramg_payment_refund_reconciliations r
      WHERE r.refund_id=v_old.id;
    END IF;
  END IF;

  INSERT INTO public.vbgramg_ledger_audit
    (ledger_entry_id,job_card_number,action,actor_user_id,actor_email,before_data,after_data)
  VALUES
    (v_old.id,v_old.job_card_number,'edit',p_actor_user_id,p_actor_email,
     pg_catalog.to_jsonb(v_old)||pg_catalog.jsonb_build_object('refund_reconciliations',v_refund_reconciliations_before),
     pg_catalog.to_jsonb(v_updated)||pg_catalog.jsonb_build_object('refund_reconciliations',v_refund_reconciliations_after));

  RETURN pg_catalog.jsonb_build_object('ok',true,'entry',pg_catalog.to_jsonb(v_updated));
END;
$$;

REVOKE ALL ON FUNCTION public.vbgramg_edit_contribution_ledger_entry(uuid,numeric,date,text,date,boolean,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vbgramg_edit_contribution_ledger_entry(uuid,numeric,date,text,date,boolean,uuid,text) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_edit_contribution_ledger_entry(uuid,numeric,date,text,date,boolean,uuid,text) TO service_role;
