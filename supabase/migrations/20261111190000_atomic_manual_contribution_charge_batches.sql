-- Atomic manual contribution charge batches (regular and extra).
-- All rows commit or roll back together. Card locks follow the shared contribution lock order.
CREATE OR REPLACE FUNCTION public.vbgramg_save_manual_contribution_charges(
  p_entries jsonb,
  p_charge_kind text,
  p_period_id uuid,
  p_charge_period date,
  p_entry_date date,
  p_reason text,
  p_actor_user_id uuid,
  p_actor_email text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO ''
AS $function$
DECLARE
  v_card record;
  v_row record;
  v_round public.vbgramg_periods%ROWTYPE;
  v_entry public.vbgramg_charge_ledger%ROWTYPE;
  v_extra public.vbgramg_contribution_extras%ROWTYPE;
  v_result_entries jsonb := '[]'::jsonb;
  v_total numeric(14,2) := 0;
  v_count integer := 0;
  v_reason text := pg_catalog.left(pg_catalog.btrim(COALESCE(p_reason,'')),500);
  v_note text;
  v_name text;
  v_error text;
BEGIN
  IF p_charge_kind IS NULL OR p_charge_kind NOT IN ('regular','extra') THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Choose regular or extra charge.');
  END IF;
  IF p_period_id IS NULL OR p_charge_period IS NULL
     OR EXTRACT(day FROM p_charge_period)<>1 THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Choose a valid contribution round and month.');
  END IF;
  IF p_actor_user_id IS NULL OR v_reason='' THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Entry date, reason, and administrator are required.');
  END IF;
  IF p_entries IS NULL OR pg_catalog.jsonb_typeof(p_entries)<>'array' THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','A batch must be a JSON array of job cards.');
  END IF;
  IF pg_catalog.jsonb_array_length(p_entries)<1 OR pg_catalog.jsonb_array_length(p_entries)>500 THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','A batch must contain 1–500 job cards.');
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(p_entries) AS row_value
    WHERE pg_catalog.jsonb_typeof(row_value)<>'object'
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Every batch row must be a job-card object.');
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_entries)
      AS x(job_card_number text, amount numeric)
    GROUP BY pg_catalog.btrim(COALESCE(job_card_number,''))
    HAVING pg_catalog.count(*)>1 OR pg_catalog.btrim(COALESCE(job_card_number,''))=''
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Job cards must be non-empty and unique within the batch.');
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_entries)
      AS x(job_card_number text, amount numeric, entry_date date)
    WHERE amount IS NULL OR amount<=0 OR amount>10000000 OR COALESCE(entry_date,p_entry_date) IS NULL
       OR amount::text IN ('NaN','Infinity','-Infinity')
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','Every job card must have a valid positive amount.');
  END IF;

  -- Household locks are acquired in deterministic order before period locks.
  FOR v_card IN
    SELECT DISTINCT pg_catalog.btrim(x.job_card_number) AS job_card_number
    FROM pg_catalog.jsonb_to_recordset(p_entries)
      AS x(job_card_number text, amount numeric)
    ORDER BY 1
  LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('vbgramg-contribution:'||v_card.job_card_number,0)
    );
  END LOOP;
  FOR v_card IN
    SELECT DISTINCT pg_catalog.btrim(x.job_card_number) AS job_card_number
    FROM pg_catalog.jsonb_to_recordset(p_entries)
      AS x(job_card_number text, amount numeric)
    ORDER BY 1
  LOOP
    PERFORM pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('contribution:'||v_card.job_card_number||':'||p_period_id::text,0)
    );
  END LOOP;

  SELECT * INTO v_round FROM public.vbgramg_periods
  WHERE id=p_period_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',404,'error','The selected contribution round was not found.');
  END IF;
  IF COALESCE(v_round.status,'open')<>'open' THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','This contribution round is closed. Reopen it before adding charges.');
  END IF;
  IF COALESCE(v_round.contribution_month,v_round.period_date) IS NULL
     OR pg_catalog.date_trunc('month',COALESCE(v_round.contribution_month,v_round.period_date))::date<>p_charge_period THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',400,'error','The selected contribution round does not match the chosen month.');
  END IF;

  -- Validate the entire batch before the first write. Do not replace an
  -- existing extra charge or duplicate a manual regular charge.
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_entries) AS x(job_card_number text, amount numeric, entry_date date)
    JOIN public.vbgramg_contribution_exemptions e
      ON pg_catalog.btrim(e.job_card_number)=pg_catalog.btrim(x.job_card_number)
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','At least one selected job card is exempted. No charges were saved.');
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_entries) AS x(job_card_number text, amount numeric, entry_date date)
    WHERE NOT EXISTS (SELECT 1 FROM public.vbgramg_contribution_citizens c WHERE c.job_card_number=pg_catalog.btrim(x.job_card_number))
      AND NOT EXISTS (SELECT 1 FROM public.vbgramg_charge_ledger l WHERE l.job_card_number=pg_catalog.btrim(x.job_card_number))
      AND NOT EXISTS (
        SELECT 1
        FROM public.vbgramg_mis_state ms
        JOIN public.vbgramg_mis_contribution_lookup lookup ON lookup.import_id=ms.active_import_id
        CROSS JOIN LATERAL pg_catalog.jsonb_to_recordset(COALESCE(lookup.payload->'citizens','[]'::jsonb))
          AS mis_card(job_card_number text,person_name text)
        WHERE ms.singleton IS TRUE AND mis_card.job_card_number=pg_catalog.btrim(x.job_card_number)
      )
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',404,'error','At least one job card is not present in contribution records. No charges were saved.');
  END IF;
  IF p_charge_kind='regular' AND EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_entries) AS x(job_card_number text, amount numeric, entry_date date)
    JOIN public.vbgramg_charge_ledger l
      ON l.job_card_number=pg_catalog.btrim(x.job_card_number)
     AND (l.period_id=p_period_id OR (l.period_id IS NULL AND l.charge_period=p_charge_period)) AND l.entry_type='charge'
     AND NOT COALESCE(l.is_voided,false)
     AND pg_catalog.left(pg_catalog.btrim(COALESCE(l.note,'')),14)='MANUAL CHARGE:'
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','A manual regular charge already exists for at least one selected job card in this round. No charges were saved.');
  END IF;
  IF p_charge_kind='extra' AND EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_entries) AS x(job_card_number text, amount numeric, entry_date date)
    JOIN public.vbgramg_contribution_extras e
      ON e.job_card_number=pg_catalog.btrim(x.job_card_number) AND e.period_id=p_period_id
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','An extra charge already exists for at least one selected job card in this round. Review the existing charge first. No charges were saved.');
  END IF;
  IF p_charge_kind='extra' AND EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_to_recordset(p_entries) AS x(job_card_number text, amount numeric, entry_date date)
    JOIN public.vbgramg_charge_ledger l
      ON l.job_card_number=pg_catalog.btrim(x.job_card_number)
     AND (l.period_id=p_period_id OR (l.period_id IS NULL AND l.charge_period=p_charge_period))
     AND l.entry_type='charge' AND NOT COALESCE(l.is_voided,false)
     AND pg_catalog.left(pg_catalog.btrim(COALESCE(l.note,'')),9)='FTO EXTRA'
  ) THEN
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,'error','An extra ledger charge already exists for at least one selected job card in this round. Review the existing charge first. No charges were saved.');
  END IF;

  v_note := CASE WHEN p_charge_kind='extra' THEN 'FTO EXTRA: ' ELSE 'MANUAL CHARGE: ' END || v_reason;

  BEGIN
  FOR v_row IN
    SELECT pg_catalog.btrim(x.job_card_number) AS job_card_number,
           x.amount::numeric(14,2) AS amount,
           COALESCE(x.entry_date,p_entry_date) AS entry_date
    FROM pg_catalog.jsonb_to_recordset(p_entries)
      AS x(job_card_number text, amount numeric, entry_date date)
    ORDER BY pg_catalog.btrim(x.job_card_number)
  LOOP
    v_entry := NULL;
    IF v_row.entry_date IS NULL THEN
      RAISE EXCEPTION 'A valid entry date is required for job card %.',v_row.job_card_number;
    END IF;
    IF EXISTS (SELECT 1 FROM public.vbgramg_contribution_exemptions e
               WHERE pg_catalog.btrim(e.job_card_number)=v_row.job_card_number) THEN
      RAISE EXCEPTION 'Job card % is exempted. No charges were saved.',v_row.job_card_number;
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.vbgramg_contribution_exemptions e
      WHERE pg_catalog.btrim(e.job_card_number)=v_row.job_card_number
    ) THEN
      RAISE EXCEPTION 'Job card % is exempted. No charges were saved.',v_row.job_card_number;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM public.vbgramg_contribution_citizens c WHERE c.job_card_number=v_row.job_card_number
      UNION ALL SELECT 1 FROM public.vbgramg_charge_ledger l WHERE l.job_card_number=v_row.job_card_number
      UNION ALL
      SELECT 1
      FROM public.vbgramg_mis_state ms
      JOIN public.vbgramg_mis_contribution_lookup lookup ON lookup.import_id=ms.active_import_id
      CROSS JOIN LATERAL pg_catalog.jsonb_to_recordset(COALESCE(lookup.payload->'citizens','[]'::jsonb))
        AS mis_card(job_card_number text,person_name text)
      WHERE ms.singleton IS TRUE AND mis_card.job_card_number=v_row.job_card_number
    ) THEN
      RAISE EXCEPTION 'Job card % is not present in contribution records. No charges were saved.',v_row.job_card_number;
    END IF;
    IF p_charge_kind='regular' AND EXISTS (
      SELECT 1 FROM public.vbgramg_charge_ledger l
      WHERE l.job_card_number=v_row.job_card_number
        AND (l.period_id=p_period_id OR (l.period_id IS NULL AND l.charge_period=p_charge_period))
        AND l.entry_type='charge' AND NOT COALESCE(l.is_voided,false)
        AND pg_catalog.left(pg_catalog.btrim(COALESCE(l.note,'')),14)='MANUAL CHARGE:'
    ) THEN
      RAISE EXCEPTION 'A manual regular charge already exists for job card % in this round. No charges were saved.',v_row.job_card_number;
    END IF;

    v_name := NULL;
    SELECT c.person_name INTO v_name
    FROM public.vbgramg_contribution_citizens c
    WHERE c.job_card_number=v_row.job_card_number LIMIT 1;
    IF v_name IS NULL OR pg_catalog.btrim(v_name)='' THEN
      SELECT mis_card.person_name INTO v_name
      FROM public.vbgramg_mis_state ms
      JOIN public.vbgramg_mis_contribution_lookup lookup ON lookup.import_id=ms.active_import_id
      CROSS JOIN LATERAL pg_catalog.jsonb_to_recordset(COALESCE(lookup.payload->'citizens','[]'::jsonb))
        AS mis_card(job_card_number text,person_name text)
      WHERE ms.singleton IS TRUE AND mis_card.job_card_number=v_row.job_card_number
      LIMIT 1;
    END IF;
    IF v_name IS NULL OR pg_catalog.btrim(v_name)='' THEN
      SELECT l.person_name INTO v_name FROM public.vbgramg_charge_ledger l
      WHERE l.job_card_number=v_row.job_card_number ORDER BY l.created_at,l.id LIMIT 1;
    END IF;
    IF v_name IS NULL OR pg_catalog.btrim(v_name)='' THEN
      RAISE EXCEPTION 'Could not resolve the household name for job card %.',v_row.job_card_number;
    END IF;

    INSERT INTO public.vbgramg_charge_ledger
      (job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note,is_deferred,created_by)
    VALUES (v_row.job_card_number,pg_catalog.btrim(v_name),'charge',v_row.amount,
      p_charge_period,p_period_id,v_row.entry_date,pg_catalog.left(v_note,200),false,p_actor_user_id)
    RETURNING * INTO v_entry;
    IF v_entry.id IS NULL THEN
      RAISE EXCEPTION 'The contribution ledger rejected the manual charge for job card %.',v_row.job_card_number;
    END IF;

    IF p_charge_kind='extra' THEN
      INSERT INTO public.vbgramg_contribution_extras
        (job_card_number,person_name,charge_period,period_id,amount,reason,ledger_entry_id,created_by,updated_by)
      VALUES (v_row.job_card_number,pg_catalog.btrim(v_name),p_charge_period,p_period_id,
        v_row.amount,v_reason,v_entry.id,p_actor_user_id,p_actor_user_id)
      RETURNING * INTO v_extra;
      IF v_extra.id IS NULL THEN
        RAISE EXCEPTION 'The extra-charge record was not saved for job card %.',v_row.job_card_number;
      END IF;
    END IF;

    INSERT INTO public.vbgramg_ledger_audit
      (ledger_entry_id,job_card_number,action,actor_user_id,actor_email,before_data,after_data)
    VALUES (v_entry.id,v_row.job_card_number,
      CASE WHEN p_charge_kind='extra' THEN 'manual_contribution_extra_charge' ELSE 'manual_contribution_charge' END,
      p_actor_user_id,pg_catalog.lower(pg_catalog.btrim(COALESCE(p_actor_email,''))),NULL,
      pg_catalog.jsonb_build_object('charge_kind',p_charge_kind,'amount',v_entry.amount,
        'period_id',p_period_id,'charge_period',p_charge_period,'entry_date',v_row.entry_date,'reason',v_reason));

    v_result_entries := v_result_entries || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object('id',v_entry.id,'job_card_number',v_entry.job_card_number,
        'person_name',v_entry.person_name,'entry_type',v_entry.entry_type,'amount',v_entry.amount,
        'charge_period',v_entry.charge_period,'period_id',v_entry.period_id,'entry_date',v_entry.entry_date,
        'note',v_entry.note,'created_at',v_entry.created_at,'is_deferred',v_entry.is_deferred,
        'is_voided',v_entry.is_voided)
    );
    v_count := v_count+1;
    v_total := v_total+v_row.amount;
  END LOOP;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    RETURN pg_catalog.jsonb_build_object('ok',false,'status',409,
      'error',COALESCE(v_error,'Manual charge batch failed. All changes were rolled back.'));
  END;

  RETURN pg_catalog.jsonb_build_object('ok',true,'charge_kind',p_charge_kind,
    'count',v_count,'total_amount',v_total,'entries',v_result_entries);
END;
$function$;

REVOKE ALL ON FUNCTION public.vbgramg_save_manual_contribution_charges(jsonb,text,uuid,date,date,text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vbgramg_save_manual_contribution_charges(jsonb,text,uuid,date,date,text,uuid,text) FROM anon,authenticated;
GRANT EXECUTE ON FUNCTION public.vbgramg_save_manual_contribution_charges(jsonb,text,uuid,date,date,text,uuid,text) TO service_role;
