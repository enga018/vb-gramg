-- Atomic create/update for an extra contribution charge and its linked ledger row.
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
  v_extra public.vbgramg_contribution_extras%ROWTYPE;
  v_name text;
  v_note text;
  v_updated boolean := false;
  v_rows integer;
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
    SELECT * INTO v_entry FROM public.vbgramg_charge_ledger
    WHERE id=v_old.ledger_entry_id FOR UPDATE;
    IF FOUND THEN
      IF v_entry.job_card_number<>v_card OR v_entry.entry_type<>'charge' THEN
        RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,
          'error','The existing extra charge is linked to an incompatible ledger entry. No changes were made.');
      END IF;
      UPDATE public.vbgramg_charge_ledger
      SET person_name=v_name,amount=p_amount,entry_date=p_entry_date,note=v_note,
          charge_period=p_charge_period,period_id=p_period_id,is_deferred=false
      WHERE id=v_entry.id RETURNING * INTO v_entry;
      GET DIAGNOSTICS v_rows=ROW_COUNT;
      IF v_rows<>1 THEN RAISE EXCEPTION 'The contribution ledger rejected the extra charge update for job card %.',v_card; END IF;
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

  RETURN pg_catalog.jsonb_build_object(
    'ok',true,'updated',v_updated,
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
