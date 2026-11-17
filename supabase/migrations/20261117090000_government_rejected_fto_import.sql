create or replace function public.vbgramg_import_rejected_fto_batches(
  p_payload jsonb,
  p_actor uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $$
declare
  v_active_import_id uuid;
  v_mis_updated_at timestamptz;
  v_period record;
  v_fto jsonb;
  v_row jsonb;
  v_prepared jsonb := '[]'::jsonb;
  v_fto_number text;
  v_card text;
  v_reference text;
  v_job_card_source text;
  v_status text;
  v_reason text;
  v_person text;
  v_village text;
  v_transaction_date date;
  v_processed_date date;
  v_transaction_date_text text;
  v_processed_date_text text;
  v_amount_text text;
  v_credit_text text;
  v_amount numeric;
  v_credit numeric;
  v_transaction_id uuid;
  v_source_row jsonb;
  v_batch_id uuid;
  v_email text;
  v_count integer := 0;
  v_total_amount numeric := 0;
  v_expected_count integer;
  v_expected_amount numeric;
  v_fto_amount numeric;
  v_fto_rows integer;
  v_seen_refs text[] := array[]::text[];
  v_seen_cards text[] := array[]::text[];
  v_now timestamptz := now();
  v_results jsonb := '[]'::jsonb;
  v_fto_expected jsonb := jsonb_build_array(
    jsonb_build_object('number','2207001000SSPAYREQ25082026114','count',297,'amount',581400),
    jsonb_build_object('number','2207001000SSPAYREQ25082026117','count',54,'amount',105300),
    jsonb_build_object('number','2207001000SSPAYREQ20082026365','count',3,'amount',5400)
  );
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Import payload is invalid.';
  end if;
  if p_actor is null then raise exception 'Administrator identity is missing.'; end if;

  select lower(u.email) into v_email from auth.users u where u.id = p_actor;
  if v_email is null or not exists (
    select 1 from public.vbgramg_approved_users a
    where a.email = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can import Government FTO batches.';
  end if;

  if coalesce(p_payload#>>'{previewMeta,sourceSha256}','') !~ '^[a-f0-9]{64}    raise exception 'Exactly three audited Government FTO batches are required.';
  end if;

  select active_import_id, updated_at
    into v_active_import_id, v_mis_updated_at
  from public.vbgramg_mis_state
  where singleton = true
  for share;

  if v_active_import_id is null
    or v_active_import_id::text <> coalesce(p_payload#>>'{previewMeta,activeImportId}','')
    or v_mis_updated_at <> nullif(p_payload#>>'{previewMeta,misUpdatedAt}','')::timestamptz then
    raise exception 'The active MIS changed after this preview. Generate a fresh Government FTO preview.';
  end if;

  select * into v_period
  from public.vbgramg_periods
  where period_name = 'JUL26' and contribution_month = date '2026-07-01'
  for share;
  if not found or v_period.status <> 'open' then
    raise exception 'Contribution period JUL26 is missing or not open.';
  end if;

  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := coalesce(v_fto->>'ftoNumber','');
    select (x->>'count')::integer, (x->>'amount')::numeric
      into v_expected_count, v_expected_amount
    from jsonb_array_elements(v_fto_expected) x
    where x->>'number' = v_fto_number;
    if v_expected_count is null then raise exception 'Unexpected FTO number: %.', v_fto_number; end if;
    if jsonb_typeof(v_fto->'rows') <> 'array' then raise exception 'FTO % has no transaction rows.', v_fto_number; end if;
    if jsonb_array_length(v_fto->'rows') <> v_expected_count then
      raise exception 'FTO % has an unexpected transaction count.', v_fto_number;
    end if;
    if exists (select 1 from public.vbgramg_fto_batches b where b.fto_number = v_fto_number) then
      raise exception 'FTO batch % already exists. Nothing was imported.', v_fto_number;
    end if;

    v_fto_rows := 0;
    v_fto_amount := 0;
    for v_row in select value from jsonb_array_elements(v_fto->'rows')
    loop
      v_fto_rows := v_fto_rows + 1;
      v_card := btrim(coalesce(v_row->>'jobCardNo',''));
      v_reference := btrim(coalesce(v_row->>'referenceNo',''));
      if coalesce(v_row->>'ftoNumber','') <> v_fto_number then raise exception 'A row has an FTO number mismatch.'; end if;
      if lower(coalesce(v_row->>'normalizedStatus','')) <> 'rejected' then raise exception 'FTO % contains a non-rejected transaction.', v_fto_number; end if;
      if v_card = '' or v_reference = '' then raise exception 'FTO % contains a missing Job Card or reference number.', v_fto_number; end if;
      if v_card = any(v_seen_cards) then raise exception 'A Job Card is duplicated across the three FTOs: %.', v_card; end if;
      if v_reference = any(v_seen_refs) then raise exception 'A reference number is duplicated across the three FTOs: %.', v_reference; end if;
      v_seen_cards := array_append(v_seen_cards, v_card);
      v_seen_refs := array_append(v_seen_refs, v_reference);

      if exists (select 1 from public.vbgramg_fto_transactions t where t.reference_no = v_reference) then
        raise exception 'Reference number % already exists in FTO history.', v_reference;
      end if;
      if not exists (
        select 1 from public.vbgramg_mis_rows m
        where m.import_id = v_active_import_id and m.row_data->>0 = v_card
      ) then
        raise exception 'Job Card % is no longer an exact match in the active MIS.', v_card;
      end if;

      if jsonb_typeof(v_row->'columns') <> 'array' or jsonb_array_length(v_row->'columns') = 0 then
        raise exception 'Raw Government source columns are missing for reference %.', v_reference;
      end if;
      select jsonb_agg(coalesce(c->>'value','') order by ordinality)
        into v_source_row
      from jsonb_array_elements(v_row->'columns') with ordinality as a(c, ordinality);

      -- Extract named raw Government columns independently for a clear and stable mapping.
      select
        max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
        max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
        max(c->>'value') filter (where c->>'name' = 'Status'),
        max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
        max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
        max(c->>'value') filter (where c->>'name' = 'Processed Date'),
        max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
        max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
      into v_job_card_source, v_person, v_status, v_reason, v_transaction_date_text,
           v_processed_date_text, v_amount_text, v_credit_text
      from jsonb_array_elements(v_row->'columns') as a(c);

      if split_part(coalesce(v_job_card_source,''), ' (', 1) <> v_card then
        raise exception 'Raw Job Card value does not match the exact MIS Job Card %.', v_card;
      end if;
      if lower(coalesce(v_status,'')) <> 'rejected' or coalesce(v_reason,'') <> 'Rejected by DDO' then
        raise exception 'FTO % contains a status or rejection-reason mismatch.', v_fto_number;
      end if;
      if coalesce(v_person,'') = '' then raise exception 'Applicant name is missing for Job Card %.', v_card; end if;
      if coalesce(v_amount_text,'') !~ '^[0-9,]+(\.[0-9]+)?$' or coalesce(v_credit_text,'') !~ '^[0-9,]+(\.[0-9]+)?$' then
        raise exception 'An amount is invalid for Job Card %.', v_card;
      end if;
      v_amount := replace(v_amount_text,',','')::numeric;
      v_credit := replace(v_credit_text,',','')::numeric;
      if v_amount < 0 or v_credit < 0 then raise exception 'A negative amount was found for Job Card %.', v_card; end if;
      v_fto_amount := v_fto_amount + v_amount;

      if coalesce(v_transaction_date_text,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_transaction_date := to_date(v_transaction_date_text,'DD/MM/YYYY');
      elsif coalesce(v_transaction_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_transaction_date := v_transaction_date_text::date
      else
        v_transaction_date := null;
      end if;
      if coalesce(v_processed_date_text,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_processed_date := to_date(v_processed_date_text,'DD/MM/YYYY');
      elsif coalesce(v_processed_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_processed_date := v_processed_date_text::date
      else
        v_processed_date := null;
      end if;

      v_village := (regexp_match(coalesce(v_job_card_source,''), '\(([^)]*)\)'))[1];
      v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
        'ftoNumber',v_fto_number,'referenceNo',v_reference,'jobCardNo',v_card,
        'personName',btrim(v_person),'villageName',coalesce(v_village,'NEW SERCHHIP North'),
        'transactionDate',v_transaction_date,'processedDate',v_processed_date,
        'amount',v_amount,'creditAmount',v_credit,'sourceRow',v_source_row
      ));
    end loop;

    if v_fto_rows <> v_expected_count or v_fto_amount <> v_expected_amount then
      raise exception 'FTO % count or total amount does not match the audited values.', v_fto_number;
    end if;
    v_count := v_count + v_fto_rows;
    v_total_amount := v_total_amount + v_fto_amount;
  end loop;

  if v_count <> 354 or v_total_amount <> 692100 or cardinality(v_seen_cards) <> 354 or cardinality(v_seen_refs) <> 354 then
    raise exception 'The combined Government FTO totals do not match the approved audit.';
  end if;
  if (select count(*) from jsonb_array_elements(p_payload->'ftos')) <> 3 then
    raise exception 'The Government FTO payload is incomplete.';
  end if;

  -- All validations are complete. The following inserts run in this single database transaction.
  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := v_fto->>'ftoNumber';
    insert into public.vbgramg_fto_batches(
      fto_number, contribution_period, ledger_charge_period, village_scope,
      last_source_sha256, created_by, notes, period_id, revision_number
    ) values (
      v_fto_number, 'JUL26', date '2026-07-01', 'NEW SERCHHIP North',
      nullif(p_payload#>>'{previewMeta,sourceSha256}',''), p_actor,
      'Government FTO rejected-only import; no Contribution ledger charges created.',
      v_period.id, 1
    ) returning id into v_batch_id;

    for v_row in
      select value from jsonb_array_elements(v_prepared)
      where value->>'ftoNumber' = v_fto_number
    loop
      insert into public.vbgramg_fto_transactions(
        batch_id, reference_no, job_card_number, village_name, person_name,
        transaction_date, processed_date, amount_to_be_credited, credit_amount,
        calculated_charge, status, rejection_reason, ledger_entry_id, source_row,
        is_in_scope, is_current, last_seen_at
      ) values (
        v_batch_id, v_row->>'referenceNo', v_row->>'jobCardNo',
        v_row->>'villageName', v_row->>'personName',
        nullif(v_row->>'transactionDate','')::date,
        nullif(v_row->>'processedDate','')::date,
        (v_row->>'amount')::numeric, (v_row->>'creditAmount')::numeric,
        0, 'rejected', 'Rejected by DDO', null, v_row->'sourceRow',
        true, true, v_now
      )
      returning id into v_transaction_id;
      insert into public.vbgramg_fto_status_history(
        transaction_id, old_status, new_status, old_calculated_charge,
        new_calculated_charge, changed_by, fto_number, reference_no, note,
        new_processed_date
      ) values (
        v_transaction_id, null, 'rejected', null, 0, p_actor, v_fto_number,
        v_row->>'referenceNo', 'Transaction first recorded from Government FTO preview import.',
        nullif(v_row->>'processedDate','')::date
      );
    end loop;
    v_results := v_results || jsonb_build_array(jsonb_build_object('fto_number',v_fto_number));
  end loop;

  return jsonb_build_object(
    'ok', true, 'batch_count', 3, 'transaction_count', 354,
    'status_history_count', 354, 'ledger_rows_created', 0, 'batches', v_results
  );
end;
$$;

revoke all on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) from public, anon, authenticated;
grant execute on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) to service_role;

    or coalesce(p_payload#>>'{previewMeta,listingFingerprint}','') !~ '^[a-f0-9]{64}    raise exception 'Exactly three audited Government FTO batches are required.';
  end if;

  select active_import_id, updated_at
    into v_active_import_id, v_mis_updated_at
  from public.vbgramg_mis_state
  where singleton = true
  for share;

  if v_active_import_id is null
    or v_active_import_id::text <> coalesce(p_payload#>>'{previewMeta,activeImportId}','')
    or v_mis_updated_at <> nullif(p_payload#>>'{previewMeta,misUpdatedAt}','')::timestamptz then
    raise exception 'The active MIS changed after this preview. Generate a fresh Government FTO preview.';
  end if;

  select * into v_period
  from public.vbgramg_periods
  where period_name = 'JUL26' and contribution_month = date '2026-07-01'
  for share;
  if not found or v_period.status <> 'open' then
    raise exception 'Contribution period JUL26 is missing or not open.';
  end if;

  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := coalesce(v_fto->>'ftoNumber','');
    select (x->>'count')::integer, (x->>'amount')::numeric
      into v_expected_count, v_expected_amount
    from jsonb_array_elements(v_fto_expected) x
    where x->>'number' = v_fto_number;
    if v_expected_count is null then raise exception 'Unexpected FTO number: %.', v_fto_number; end if;
    if jsonb_typeof(v_fto->'rows') <> 'array' then raise exception 'FTO % has no transaction rows.', v_fto_number; end if;
    if jsonb_array_length(v_fto->'rows') <> v_expected_count then
      raise exception 'FTO % has an unexpected transaction count.', v_fto_number;
    end if;
    if exists (select 1 from public.vbgramg_fto_batches b where b.fto_number = v_fto_number) then
      raise exception 'FTO batch % already exists. Nothing was imported.', v_fto_number;
    end if;

    v_fto_rows := 0;
    v_fto_amount := 0;
    for v_row in select value from jsonb_array_elements(v_fto->'rows')
    loop
      v_fto_rows := v_fto_rows + 1;
      v_card := btrim(coalesce(v_row->>'jobCardNo',''));
      v_reference := btrim(coalesce(v_row->>'referenceNo',''));
      if coalesce(v_row->>'ftoNumber','') <> v_fto_number then raise exception 'A row has an FTO number mismatch.'; end if;
      if lower(coalesce(v_row->>'normalizedStatus','')) <> 'rejected' then raise exception 'FTO % contains a non-rejected transaction.', v_fto_number; end if;
      if v_card = '' or v_reference = '' then raise exception 'FTO % contains a missing Job Card or reference number.', v_fto_number; end if;
      if v_card = any(v_seen_cards) then raise exception 'A Job Card is duplicated across the three FTOs: %.', v_card; end if;
      if v_reference = any(v_seen_refs) then raise exception 'A reference number is duplicated across the three FTOs: %.', v_reference; end if;
      v_seen_cards := array_append(v_seen_cards, v_card);
      v_seen_refs := array_append(v_seen_refs, v_reference);

      if exists (select 1 from public.vbgramg_fto_transactions t where t.reference_no = v_reference) then
        raise exception 'Reference number % already exists in FTO history.', v_reference;
      end if;
      if not exists (
        select 1 from public.vbgramg_mis_rows m
        where m.import_id = v_active_import_id and m.row_data->>0 = v_card
      ) then
        raise exception 'Job Card % is no longer an exact match in the active MIS.', v_card;
      end if;

      select jsonb_agg(coalesce(c->>'value','') order by ordinality),
             max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
             max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
             max(c->>'value') filter (where c->>'name' = 'Status'),
             max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
             max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
             max(c->>'value') filter (where c->>'name' = 'Processed Date'),
             max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
             max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
        into v_source_row, v_job_card_source, v_person, v_status, v_reason,
             v_job_card_source, v_processed_date, v_person, v_credit, v_amount
      from jsonb_array_elements(v_row->'columns') with ordinality as a(c, ordinality);

      -- Extract named raw Government columns independently for a clear and stable mapping.
      select
        max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
        max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
        max(c->>'value') filter (where c->>'name' = 'Status'),
        max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
        max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
        max(c->>'value') filter (where c->>'name' = 'Processed Date'),
        max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
        max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
      into v_job_card_source, v_person, v_status, v_reason, v_transaction_date,
           v_processed_date, v_amount, v_credit
      from jsonb_array_elements(v_row->'columns') as a(c);

      if split_part(coalesce(v_job_card_source,''), ' (', 1) <> v_card then
        raise exception 'Raw Job Card value does not match the exact MIS Job Card %.', v_card;
      end if;
      if lower(coalesce(v_status,'')) <> 'rejected' or coalesce(v_reason,'') <> 'Rejected by DDO' then
        raise exception 'FTO % contains a status or rejection-reason mismatch.', v_fto_number;
      end if;
      if coalesce(v_person,'') = '' then raise exception 'Applicant name is missing for Job Card %.', v_card; end if;
      if coalesce(v_amount,'') !~ '^[0-9,]+(\.[0-9]+)?$' or coalesce(v_credit,'') !~ '^[0-9,]+(\.[0-9]+)?$' then
        raise exception 'An amount is invalid for Job Card %.', v_card;
      end if;
      v_amount := replace(v_amount,',','')::numeric;
      v_credit := replace(v_credit,',','')::numeric;
      if v_amount < 0 or v_credit < 0 then raise exception 'A negative amount was found for Job Card %.', v_card; end if;
      v_fto_amount := v_fto_amount + v_amount;

      if coalesce(v_transaction_date,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_transaction_date := to_date(v_transaction_date,'DD/MM/YYYY');
      elsif coalesce(v_transaction_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_transaction_date := v_transaction_date::date;
      else
        v_transaction_date := null;
      end if;
      if coalesce(v_processed_date,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_processed_date := to_date(v_processed_date,'DD/MM/YYYY');
      elsif coalesce(v_processed_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_processed_date := v_processed_date::date;
      else
        v_processed_date := null;
      end if;

      v_village := (regexp_match(coalesce(v_job_card_source,''), '\(([^)]*)\)'))[1];
      v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
        'ftoNumber',v_fto_number,'referenceNo',v_reference,'jobCardNo',v_card,
        'personName',btrim(v_person),'villageName',coalesce(v_village,'NEW SERCHHIP North'),
        'transactionDate',v_transaction_date,'processedDate',v_processed_date,
        'amount',v_amount,'creditAmount',v_credit,'sourceRow',v_source_row
      ));
    end loop;

    if v_fto_rows <> v_expected_count or v_fto_amount <> v_expected_amount then
      raise exception 'FTO % count or total amount does not match the audited values.', v_fto_number;
    end if;
    v_count := v_count + v_fto_rows;
    v_total_amount := v_total_amount + v_fto_amount;
  end loop;

  if v_count <> 354 or v_total_amount <> 692100 or cardinality(v_seen_cards) <> 354 or cardinality(v_seen_refs) <> 354 then
    raise exception 'The combined Government FTO totals do not match the approved audit.';
  end if;
  if (select count(*) from jsonb_array_elements(p_payload->'ftos')) <> 3 then
    raise exception 'The Government FTO payload is incomplete.';
  end if;

  -- All validations are complete. The following inserts run in this single database transaction.
  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := v_fto->>'ftoNumber';
    insert into public.vbgramg_fto_batches(
      fto_number, contribution_period, ledger_charge_period, village_scope,
      last_source_sha256, created_by, notes, period_id, revision_number
    ) values (
      v_fto_number, 'JUL26', date '2026-07-01', 'NEW SERCHHIP North',
      nullif(p_payload#>>'{previewMeta,sourceSha256}',''), p_actor,
      'Government FTO rejected-only import; no Contribution ledger charges created.',
      v_period.id, 1
    ) returning id into v_batch_id;

    for v_row in
      select value from jsonb_array_elements(v_prepared)
      where value->>'ftoNumber' = v_fto_number
    loop
      insert into public.vbgramg_fto_transactions(
        batch_id, reference_no, job_card_number, village_name, person_name,
        transaction_date, processed_date, amount_to_be_credited, credit_amount,
        calculated_charge, status, rejection_reason, ledger_entry_id, source_row,
        is_in_scope, is_current, last_seen_at
      ) values (
        v_batch_id, v_row->>'referenceNo', v_row->>'jobCardNo',
        v_row->>'villageName', v_row->>'personName',
        nullif(v_row->>'transactionDate','')::date,
        nullif(v_row->>'processedDate','')::date,
        (v_row->>'amount')::numeric, (v_row->>'creditAmount')::numeric,
        0, 'rejected', 'Rejected by DDO', null, v_row->'sourceRow',
        true, true, v_now
      )
      returning id into v_batch_id; -- overwritten below only after the history row has been written
      -- Retrieve the transaction by its unique batch/reference identity for status history.
      insert into public.vbgramg_fto_status_history(
        transaction_id, old_status, new_status, old_calculated_charge,
        new_calculated_charge, changed_by, fto_number, reference_no, note,
        new_processed_date
      )
      select t.id, null, 'rejected', null, 0, p_actor, v_fto_number,
             t.reference_no, 'Transaction first recorded from Government FTO preview import.',
             t.processed_date
      from public.vbgramg_fto_transactions t
      where t.batch_id = (select b.id from public.vbgramg_fto_batches b where b.fto_number = v_fto_number)
        and t.reference_no = v_row->>'referenceNo';

      -- Restore the batch id after the transaction insert RETURNING clause.
      select id into v_batch_id from public.vbgramg_fto_batches where fto_number = v_fto_number;
    end loop;
    v_results := v_results || jsonb_build_array(jsonb_build_object('fto_number',v_fto_number));
  end loop;

  return jsonb_build_object(
    'ok', true, 'batch_count', 3, 'transaction_count', 354,
    'status_history_count', 354, 'ledger_rows_created', 0, 'batches', v_results
  );
end;
$$;

revoke all on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) from public, anon, authenticated;
grant execute on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) to service_role;

    or coalesce(p_payload#>>'{previewMeta,testedPages}','') !~ '^[0-9]+    raise exception 'Exactly three audited Government FTO batches are required.';
  end if;

  select active_import_id, updated_at
    into v_active_import_id, v_mis_updated_at
  from public.vbgramg_mis_state
  where singleton = true
  for share;

  if v_active_import_id is null
    or v_active_import_id::text <> coalesce(p_payload#>>'{previewMeta,activeImportId}','')
    or v_mis_updated_at <> nullif(p_payload#>>'{previewMeta,misUpdatedAt}','')::timestamptz then
    raise exception 'The active MIS changed after this preview. Generate a fresh Government FTO preview.';
  end if;

  select * into v_period
  from public.vbgramg_periods
  where period_name = 'JUL26' and contribution_month = date '2026-07-01'
  for share;
  if not found or v_period.status <> 'open' then
    raise exception 'Contribution period JUL26 is missing or not open.';
  end if;

  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := coalesce(v_fto->>'ftoNumber','');
    select (x->>'count')::integer, (x->>'amount')::numeric
      into v_expected_count, v_expected_amount
    from jsonb_array_elements(v_fto_expected) x
    where x->>'number' = v_fto_number;
    if v_expected_count is null then raise exception 'Unexpected FTO number: %.', v_fto_number; end if;
    if jsonb_typeof(v_fto->'rows') <> 'array' then raise exception 'FTO % has no transaction rows.', v_fto_number; end if;
    if jsonb_array_length(v_fto->'rows') <> v_expected_count then
      raise exception 'FTO % has an unexpected transaction count.', v_fto_number;
    end if;
    if exists (select 1 from public.vbgramg_fto_batches b where b.fto_number = v_fto_number) then
      raise exception 'FTO batch % already exists. Nothing was imported.', v_fto_number;
    end if;

    v_fto_rows := 0;
    v_fto_amount := 0;
    for v_row in select value from jsonb_array_elements(v_fto->'rows')
    loop
      v_fto_rows := v_fto_rows + 1;
      v_card := btrim(coalesce(v_row->>'jobCardNo',''));
      v_reference := btrim(coalesce(v_row->>'referenceNo',''));
      if coalesce(v_row->>'ftoNumber','') <> v_fto_number then raise exception 'A row has an FTO number mismatch.'; end if;
      if lower(coalesce(v_row->>'normalizedStatus','')) <> 'rejected' then raise exception 'FTO % contains a non-rejected transaction.', v_fto_number; end if;
      if v_card = '' or v_reference = '' then raise exception 'FTO % contains a missing Job Card or reference number.', v_fto_number; end if;
      if v_card = any(v_seen_cards) then raise exception 'A Job Card is duplicated across the three FTOs: %.', v_card; end if;
      if v_reference = any(v_seen_refs) then raise exception 'A reference number is duplicated across the three FTOs: %.', v_reference; end if;
      v_seen_cards := array_append(v_seen_cards, v_card);
      v_seen_refs := array_append(v_seen_refs, v_reference);

      if exists (select 1 from public.vbgramg_fto_transactions t where t.reference_no = v_reference) then
        raise exception 'Reference number % already exists in FTO history.', v_reference;
      end if;
      if not exists (
        select 1 from public.vbgramg_mis_rows m
        where m.import_id = v_active_import_id and m.row_data->>0 = v_card
      ) then
        raise exception 'Job Card % is no longer an exact match in the active MIS.', v_card;
      end if;

      select jsonb_agg(coalesce(c->>'value','') order by ordinality),
             max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
             max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
             max(c->>'value') filter (where c->>'name' = 'Status'),
             max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
             max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
             max(c->>'value') filter (where c->>'name' = 'Processed Date'),
             max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
             max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
        into v_source_row, v_job_card_source, v_person, v_status, v_reason,
             v_job_card_source, v_processed_date, v_person, v_credit, v_amount
      from jsonb_array_elements(v_row->'columns') with ordinality as a(c, ordinality);

      -- Extract named raw Government columns independently for a clear and stable mapping.
      select
        max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
        max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
        max(c->>'value') filter (where c->>'name' = 'Status'),
        max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
        max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
        max(c->>'value') filter (where c->>'name' = 'Processed Date'),
        max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
        max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
      into v_job_card_source, v_person, v_status, v_reason, v_transaction_date,
           v_processed_date, v_amount, v_credit
      from jsonb_array_elements(v_row->'columns') as a(c);

      if split_part(coalesce(v_job_card_source,''), ' (', 1) <> v_card then
        raise exception 'Raw Job Card value does not match the exact MIS Job Card %.', v_card;
      end if;
      if lower(coalesce(v_status,'')) <> 'rejected' or coalesce(v_reason,'') <> 'Rejected by DDO' then
        raise exception 'FTO % contains a status or rejection-reason mismatch.', v_fto_number;
      end if;
      if coalesce(v_person,'') = '' then raise exception 'Applicant name is missing for Job Card %.', v_card; end if;
      if coalesce(v_amount,'') !~ '^[0-9,]+(\.[0-9]+)?$' or coalesce(v_credit,'') !~ '^[0-9,]+(\.[0-9]+)?$' then
        raise exception 'An amount is invalid for Job Card %.', v_card;
      end if;
      v_amount := replace(v_amount,',','')::numeric;
      v_credit := replace(v_credit,',','')::numeric;
      if v_amount < 0 or v_credit < 0 then raise exception 'A negative amount was found for Job Card %.', v_card; end if;
      v_fto_amount := v_fto_amount + v_amount;

      if coalesce(v_transaction_date,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_transaction_date := to_date(v_transaction_date,'DD/MM/YYYY');
      elsif coalesce(v_transaction_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_transaction_date := v_transaction_date::date;
      else
        v_transaction_date := null;
      end if;
      if coalesce(v_processed_date,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_processed_date := to_date(v_processed_date,'DD/MM/YYYY');
      elsif coalesce(v_processed_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_processed_date := v_processed_date::date;
      else
        v_processed_date := null;
      end if;

      v_village := (regexp_match(coalesce(v_job_card_source,''), '\(([^)]*)\)'))[1];
      v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
        'ftoNumber',v_fto_number,'referenceNo',v_reference,'jobCardNo',v_card,
        'personName',btrim(v_person),'villageName',coalesce(v_village,'NEW SERCHHIP North'),
        'transactionDate',v_transaction_date,'processedDate',v_processed_date,
        'amount',v_amount,'creditAmount',v_credit,'sourceRow',v_source_row
      ));
    end loop;

    if v_fto_rows <> v_expected_count or v_fto_amount <> v_expected_amount then
      raise exception 'FTO % count or total amount does not match the audited values.', v_fto_number;
    end if;
    v_count := v_count + v_fto_rows;
    v_total_amount := v_total_amount + v_fto_amount;
  end loop;

  if v_count <> 354 or v_total_amount <> 692100 or cardinality(v_seen_cards) <> 354 or cardinality(v_seen_refs) <> 354 then
    raise exception 'The combined Government FTO totals do not match the approved audit.';
  end if;
  if (select count(*) from jsonb_array_elements(p_payload->'ftos')) <> 3 then
    raise exception 'The Government FTO payload is incomplete.';
  end if;

  -- All validations are complete. The following inserts run in this single database transaction.
  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := v_fto->>'ftoNumber';
    insert into public.vbgramg_fto_batches(
      fto_number, contribution_period, ledger_charge_period, village_scope,
      last_source_sha256, created_by, notes, period_id, revision_number
    ) values (
      v_fto_number, 'JUL26', date '2026-07-01', 'NEW SERCHHIP North',
      nullif(p_payload#>>'{previewMeta,sourceSha256}',''), p_actor,
      'Government FTO rejected-only import; no Contribution ledger charges created.',
      v_period.id, 1
    ) returning id into v_batch_id;

    for v_row in
      select value from jsonb_array_elements(v_prepared)
      where value->>'ftoNumber' = v_fto_number
    loop
      insert into public.vbgramg_fto_transactions(
        batch_id, reference_no, job_card_number, village_name, person_name,
        transaction_date, processed_date, amount_to_be_credited, credit_amount,
        calculated_charge, status, rejection_reason, ledger_entry_id, source_row,
        is_in_scope, is_current, last_seen_at
      ) values (
        v_batch_id, v_row->>'referenceNo', v_row->>'jobCardNo',
        v_row->>'villageName', v_row->>'personName',
        nullif(v_row->>'transactionDate','')::date,
        nullif(v_row->>'processedDate','')::date,
        (v_row->>'amount')::numeric, (v_row->>'creditAmount')::numeric,
        0, 'rejected', 'Rejected by DDO', null, v_row->'sourceRow',
        true, true, v_now
      )
      returning id into v_batch_id; -- overwritten below only after the history row has been written
      -- Retrieve the transaction by its unique batch/reference identity for status history.
      insert into public.vbgramg_fto_status_history(
        transaction_id, old_status, new_status, old_calculated_charge,
        new_calculated_charge, changed_by, fto_number, reference_no, note,
        new_processed_date
      )
      select t.id, null, 'rejected', null, 0, p_actor, v_fto_number,
             t.reference_no, 'Transaction first recorded from Government FTO preview import.',
             t.processed_date
      from public.vbgramg_fto_transactions t
      where t.batch_id = (select b.id from public.vbgramg_fto_batches b where b.fto_number = v_fto_number)
        and t.reference_no = v_row->>'referenceNo';

      -- Restore the batch id after the transaction insert RETURNING clause.
      select id into v_batch_id from public.vbgramg_fto_batches where fto_number = v_fto_number;
    end loop;
    v_results := v_results || jsonb_build_array(jsonb_build_object('fto_number',v_fto_number));
  end loop;

  return jsonb_build_object(
    'ok', true, 'batch_count', 3, 'transaction_count', 354,
    'status_history_count', 354, 'ledger_rows_created', 0, 'batches', v_results
  );
end;
$$;

revoke all on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) from public, anon, authenticated;
grant execute on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) to service_role;

    or coalesce(p_payload#>>'{previewMeta,listingCandidateCount}','') !~ '^[0-9]+    raise exception 'Exactly three audited Government FTO batches are required.';
  end if;

  select active_import_id, updated_at
    into v_active_import_id, v_mis_updated_at
  from public.vbgramg_mis_state
  where singleton = true
  for share;

  if v_active_import_id is null
    or v_active_import_id::text <> coalesce(p_payload#>>'{previewMeta,activeImportId}','')
    or v_mis_updated_at <> nullif(p_payload#>>'{previewMeta,misUpdatedAt}','')::timestamptz then
    raise exception 'The active MIS changed after this preview. Generate a fresh Government FTO preview.';
  end if;

  select * into v_period
  from public.vbgramg_periods
  where period_name = 'JUL26' and contribution_month = date '2026-07-01'
  for share;
  if not found or v_period.status <> 'open' then
    raise exception 'Contribution period JUL26 is missing or not open.';
  end if;

  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := coalesce(v_fto->>'ftoNumber','');
    select (x->>'count')::integer, (x->>'amount')::numeric
      into v_expected_count, v_expected_amount
    from jsonb_array_elements(v_fto_expected) x
    where x->>'number' = v_fto_number;
    if v_expected_count is null then raise exception 'Unexpected FTO number: %.', v_fto_number; end if;
    if jsonb_typeof(v_fto->'rows') <> 'array' then raise exception 'FTO % has no transaction rows.', v_fto_number; end if;
    if jsonb_array_length(v_fto->'rows') <> v_expected_count then
      raise exception 'FTO % has an unexpected transaction count.', v_fto_number;
    end if;
    if exists (select 1 from public.vbgramg_fto_batches b where b.fto_number = v_fto_number) then
      raise exception 'FTO batch % already exists. Nothing was imported.', v_fto_number;
    end if;

    v_fto_rows := 0;
    v_fto_amount := 0;
    for v_row in select value from jsonb_array_elements(v_fto->'rows')
    loop
      v_fto_rows := v_fto_rows + 1;
      v_card := btrim(coalesce(v_row->>'jobCardNo',''));
      v_reference := btrim(coalesce(v_row->>'referenceNo',''));
      if coalesce(v_row->>'ftoNumber','') <> v_fto_number then raise exception 'A row has an FTO number mismatch.'; end if;
      if lower(coalesce(v_row->>'normalizedStatus','')) <> 'rejected' then raise exception 'FTO % contains a non-rejected transaction.', v_fto_number; end if;
      if v_card = '' or v_reference = '' then raise exception 'FTO % contains a missing Job Card or reference number.', v_fto_number; end if;
      if v_card = any(v_seen_cards) then raise exception 'A Job Card is duplicated across the three FTOs: %.', v_card; end if;
      if v_reference = any(v_seen_refs) then raise exception 'A reference number is duplicated across the three FTOs: %.', v_reference; end if;
      v_seen_cards := array_append(v_seen_cards, v_card);
      v_seen_refs := array_append(v_seen_refs, v_reference);

      if exists (select 1 from public.vbgramg_fto_transactions t where t.reference_no = v_reference) then
        raise exception 'Reference number % already exists in FTO history.', v_reference;
      end if;
      if not exists (
        select 1 from public.vbgramg_mis_rows m
        where m.import_id = v_active_import_id and m.row_data->>0 = v_card
      ) then
        raise exception 'Job Card % is no longer an exact match in the active MIS.', v_card;
      end if;

      select jsonb_agg(coalesce(c->>'value','') order by ordinality),
             max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
             max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
             max(c->>'value') filter (where c->>'name' = 'Status'),
             max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
             max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
             max(c->>'value') filter (where c->>'name' = 'Processed Date'),
             max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
             max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
        into v_source_row, v_job_card_source, v_person, v_status, v_reason,
             v_job_card_source, v_processed_date, v_person, v_credit, v_amount
      from jsonb_array_elements(v_row->'columns') with ordinality as a(c, ordinality);

      -- Extract named raw Government columns independently for a clear and stable mapping.
      select
        max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
        max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
        max(c->>'value') filter (where c->>'name' = 'Status'),
        max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
        max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
        max(c->>'value') filter (where c->>'name' = 'Processed Date'),
        max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
        max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
      into v_job_card_source, v_person, v_status, v_reason, v_transaction_date,
           v_processed_date, v_amount, v_credit
      from jsonb_array_elements(v_row->'columns') as a(c);

      if split_part(coalesce(v_job_card_source,''), ' (', 1) <> v_card then
        raise exception 'Raw Job Card value does not match the exact MIS Job Card %.', v_card;
      end if;
      if lower(coalesce(v_status,'')) <> 'rejected' or coalesce(v_reason,'') <> 'Rejected by DDO' then
        raise exception 'FTO % contains a status or rejection-reason mismatch.', v_fto_number;
      end if;
      if coalesce(v_person,'') = '' then raise exception 'Applicant name is missing for Job Card %.', v_card; end if;
      if coalesce(v_amount,'') !~ '^[0-9,]+(\.[0-9]+)?$' or coalesce(v_credit,'') !~ '^[0-9,]+(\.[0-9]+)?$' then
        raise exception 'An amount is invalid for Job Card %.', v_card;
      end if;
      v_amount := replace(v_amount,',','')::numeric;
      v_credit := replace(v_credit,',','')::numeric;
      if v_amount < 0 or v_credit < 0 then raise exception 'A negative amount was found for Job Card %.', v_card; end if;
      v_fto_amount := v_fto_amount + v_amount;

      if coalesce(v_transaction_date,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_transaction_date := to_date(v_transaction_date,'DD/MM/YYYY');
      elsif coalesce(v_transaction_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_transaction_date := v_transaction_date::date;
      else
        v_transaction_date := null;
      end if;
      if coalesce(v_processed_date,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_processed_date := to_date(v_processed_date,'DD/MM/YYYY');
      elsif coalesce(v_processed_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_processed_date := v_processed_date::date;
      else
        v_processed_date := null;
      end if;

      v_village := (regexp_match(coalesce(v_job_card_source,''), '\(([^)]*)\)'))[1];
      v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
        'ftoNumber',v_fto_number,'referenceNo',v_reference,'jobCardNo',v_card,
        'personName',btrim(v_person),'villageName',coalesce(v_village,'NEW SERCHHIP North'),
        'transactionDate',v_transaction_date,'processedDate',v_processed_date,
        'amount',v_amount,'creditAmount',v_credit,'sourceRow',v_source_row
      ));
    end loop;

    if v_fto_rows <> v_expected_count or v_fto_amount <> v_expected_amount then
      raise exception 'FTO % count or total amount does not match the audited values.', v_fto_number;
    end if;
    v_count := v_count + v_fto_rows;
    v_total_amount := v_total_amount + v_fto_amount;
  end loop;

  if v_count <> 354 or v_total_amount <> 692100 or cardinality(v_seen_cards) <> 354 or cardinality(v_seen_refs) <> 354 then
    raise exception 'The combined Government FTO totals do not match the approved audit.';
  end if;
  if (select count(*) from jsonb_array_elements(p_payload->'ftos')) <> 3 then
    raise exception 'The Government FTO payload is incomplete.';
  end if;

  -- All validations are complete. The following inserts run in this single database transaction.
  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := v_fto->>'ftoNumber';
    insert into public.vbgramg_fto_batches(
      fto_number, contribution_period, ledger_charge_period, village_scope,
      last_source_sha256, created_by, notes, period_id, revision_number
    ) values (
      v_fto_number, 'JUL26', date '2026-07-01', 'NEW SERCHHIP North',
      nullif(p_payload#>>'{previewMeta,sourceSha256}',''), p_actor,
      'Government FTO rejected-only import; no Contribution ledger charges created.',
      v_period.id, 1
    ) returning id into v_batch_id;

    for v_row in
      select value from jsonb_array_elements(v_prepared)
      where value->>'ftoNumber' = v_fto_number
    loop
      insert into public.vbgramg_fto_transactions(
        batch_id, reference_no, job_card_number, village_name, person_name,
        transaction_date, processed_date, amount_to_be_credited, credit_amount,
        calculated_charge, status, rejection_reason, ledger_entry_id, source_row,
        is_in_scope, is_current, last_seen_at
      ) values (
        v_batch_id, v_row->>'referenceNo', v_row->>'jobCardNo',
        v_row->>'villageName', v_row->>'personName',
        nullif(v_row->>'transactionDate','')::date,
        nullif(v_row->>'processedDate','')::date,
        (v_row->>'amount')::numeric, (v_row->>'creditAmount')::numeric,
        0, 'rejected', 'Rejected by DDO', null, v_row->'sourceRow',
        true, true, v_now
      )
      returning id into v_batch_id; -- overwritten below only after the history row has been written
      -- Retrieve the transaction by its unique batch/reference identity for status history.
      insert into public.vbgramg_fto_status_history(
        transaction_id, old_status, new_status, old_calculated_charge,
        new_calculated_charge, changed_by, fto_number, reference_no, note,
        new_processed_date
      )
      select t.id, null, 'rejected', null, 0, p_actor, v_fto_number,
             t.reference_no, 'Transaction first recorded from Government FTO preview import.',
             t.processed_date
      from public.vbgramg_fto_transactions t
      where t.batch_id = (select b.id from public.vbgramg_fto_batches b where b.fto_number = v_fto_number)
        and t.reference_no = v_row->>'referenceNo';

      -- Restore the batch id after the transaction insert RETURNING clause.
      select id into v_batch_id from public.vbgramg_fto_batches where fto_number = v_fto_number;
    end loop;
    v_results := v_results || jsonb_build_array(jsonb_build_object('fto_number',v_fto_number));
  end loop;

  return jsonb_build_object(
    'ok', true, 'batch_count', 3, 'transaction_count', 354,
    'status_history_count', 354, 'ledger_rows_created', 0, 'batches', v_results
  );
end;
$$;

revoke all on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) from public, anon, authenticated;
grant execute on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) to service_role;

    or (p_payload#>>'{previewMeta,testedPages}')::integer <> (p_payload#>>'{previewMeta,listingCandidateCount}')::integer then
    raise exception 'Government preview integrity metadata is missing or incomplete.';
  end if;
  if jsonb_typeof(p_payload->'ftos') <> 'array' or jsonb_array_length(p_payload->'ftos') <> 3 then
    raise exception 'Exactly three audited Government FTO batches are required.';
  end if;

  select active_import_id, updated_at
    into v_active_import_id, v_mis_updated_at
  from public.vbgramg_mis_state
  where singleton = true
  for share;

  if v_active_import_id is null
    or v_active_import_id::text <> coalesce(p_payload#>>'{previewMeta,activeImportId}','')
    or v_mis_updated_at <> nullif(p_payload#>>'{previewMeta,misUpdatedAt}','')::timestamptz then
    raise exception 'The active MIS changed after this preview. Generate a fresh Government FTO preview.';
  end if;

  select * into v_period
  from public.vbgramg_periods
  where period_name = 'JUL26' and contribution_month = date '2026-07-01'
  for share;
  if not found or v_period.status <> 'open' then
    raise exception 'Contribution period JUL26 is missing or not open.';
  end if;

  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := coalesce(v_fto->>'ftoNumber','');
    select (x->>'count')::integer, (x->>'amount')::numeric
      into v_expected_count, v_expected_amount
    from jsonb_array_elements(v_fto_expected) x
    where x->>'number' = v_fto_number;
    if v_expected_count is null then raise exception 'Unexpected FTO number: %.', v_fto_number; end if;
    if jsonb_typeof(v_fto->'rows') <> 'array' then raise exception 'FTO % has no transaction rows.', v_fto_number; end if;
    if jsonb_array_length(v_fto->'rows') <> v_expected_count then
      raise exception 'FTO % has an unexpected transaction count.', v_fto_number;
    end if;
    if exists (select 1 from public.vbgramg_fto_batches b where b.fto_number = v_fto_number) then
      raise exception 'FTO batch % already exists. Nothing was imported.', v_fto_number;
    end if;

    v_fto_rows := 0;
    v_fto_amount := 0;
    for v_row in select value from jsonb_array_elements(v_fto->'rows')
    loop
      v_fto_rows := v_fto_rows + 1;
      v_card := btrim(coalesce(v_row->>'jobCardNo',''));
      v_reference := btrim(coalesce(v_row->>'referenceNo',''));
      if coalesce(v_row->>'ftoNumber','') <> v_fto_number then raise exception 'A row has an FTO number mismatch.'; end if;
      if lower(coalesce(v_row->>'normalizedStatus','')) <> 'rejected' then raise exception 'FTO % contains a non-rejected transaction.', v_fto_number; end if;
      if v_card = '' or v_reference = '' then raise exception 'FTO % contains a missing Job Card or reference number.', v_fto_number; end if;
      if v_card = any(v_seen_cards) then raise exception 'A Job Card is duplicated across the three FTOs: %.', v_card; end if;
      if v_reference = any(v_seen_refs) then raise exception 'A reference number is duplicated across the three FTOs: %.', v_reference; end if;
      v_seen_cards := array_append(v_seen_cards, v_card);
      v_seen_refs := array_append(v_seen_refs, v_reference);

      if exists (select 1 from public.vbgramg_fto_transactions t where t.reference_no = v_reference) then
        raise exception 'Reference number % already exists in FTO history.', v_reference;
      end if;
      if not exists (
        select 1 from public.vbgramg_mis_rows m
        where m.import_id = v_active_import_id and m.row_data->>0 = v_card
      ) then
        raise exception 'Job Card % is no longer an exact match in the active MIS.', v_card;
      end if;

      select jsonb_agg(coalesce(c->>'value','') order by ordinality),
             max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
             max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
             max(c->>'value') filter (where c->>'name' = 'Status'),
             max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
             max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
             max(c->>'value') filter (where c->>'name' = 'Processed Date'),
             max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
             max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
        into v_source_row, v_job_card_source, v_person, v_status, v_reason,
             v_job_card_source, v_processed_date, v_person, v_credit, v_amount
      from jsonb_array_elements(v_row->'columns') with ordinality as a(c, ordinality);

      -- Extract named raw Government columns independently for a clear and stable mapping.
      select
        max(c->>'value') filter (where c->>'name' = 'Job Card No. (Panchayat Name)'),
        max(c->>'value') filter (where c->>'name' = 'Applicant Name'),
        max(c->>'value') filter (where c->>'name' = 'Status'),
        max(c->>'value') filter (where c->>'name' = 'Rejection Reason'),
        max(c->>'value') filter (where c->>'name' = 'Transaction Date'),
        max(c->>'value') filter (where c->>'name' = 'Processed Date'),
        max(c->>'value') filter (where c->>'name' = 'Amount to be credited (In Rs.)'),
        max(c->>'value') filter (where c->>'name' = 'Credit Amount(In Rs.)')
      into v_job_card_source, v_person, v_status, v_reason, v_transaction_date,
           v_processed_date, v_amount, v_credit
      from jsonb_array_elements(v_row->'columns') as a(c);

      if split_part(coalesce(v_job_card_source,''), ' (', 1) <> v_card then
        raise exception 'Raw Job Card value does not match the exact MIS Job Card %.', v_card;
      end if;
      if lower(coalesce(v_status,'')) <> 'rejected' or coalesce(v_reason,'') <> 'Rejected by DDO' then
        raise exception 'FTO % contains a status or rejection-reason mismatch.', v_fto_number;
      end if;
      if coalesce(v_person,'') = '' then raise exception 'Applicant name is missing for Job Card %.', v_card; end if;
      if coalesce(v_amount,'') !~ '^[0-9,]+(\.[0-9]+)?$' or coalesce(v_credit,'') !~ '^[0-9,]+(\.[0-9]+)?$' then
        raise exception 'An amount is invalid for Job Card %.', v_card;
      end if;
      v_amount := replace(v_amount,',','')::numeric;
      v_credit := replace(v_credit,',','')::numeric;
      if v_amount < 0 or v_credit < 0 then raise exception 'A negative amount was found for Job Card %.', v_card; end if;
      v_fto_amount := v_fto_amount + v_amount;

      if coalesce(v_transaction_date,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_transaction_date := to_date(v_transaction_date,'DD/MM/YYYY');
      elsif coalesce(v_transaction_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_transaction_date := v_transaction_date::date;
      else
        v_transaction_date := null;
      end if;
      if coalesce(v_processed_date,'') ~ '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' then
        v_processed_date := to_date(v_processed_date,'DD/MM/YYYY');
      elsif coalesce(v_processed_date,'') ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        v_processed_date := v_processed_date::date;
      else
        v_processed_date := null;
      end if;

      v_village := (regexp_match(coalesce(v_job_card_source,''), '\(([^)]*)\)'))[1];
      v_prepared := v_prepared || jsonb_build_array(jsonb_build_object(
        'ftoNumber',v_fto_number,'referenceNo',v_reference,'jobCardNo',v_card,
        'personName',btrim(v_person),'villageName',coalesce(v_village,'NEW SERCHHIP North'),
        'transactionDate',v_transaction_date,'processedDate',v_processed_date,
        'amount',v_amount,'creditAmount',v_credit,'sourceRow',v_source_row
      ));
    end loop;

    if v_fto_rows <> v_expected_count or v_fto_amount <> v_expected_amount then
      raise exception 'FTO % count or total amount does not match the audited values.', v_fto_number;
    end if;
    v_count := v_count + v_fto_rows;
    v_total_amount := v_total_amount + v_fto_amount;
  end loop;

  if v_count <> 354 or v_total_amount <> 692100 or cardinality(v_seen_cards) <> 354 or cardinality(v_seen_refs) <> 354 then
    raise exception 'The combined Government FTO totals do not match the approved audit.';
  end if;
  if (select count(*) from jsonb_array_elements(p_payload->'ftos')) <> 3 then
    raise exception 'The Government FTO payload is incomplete.';
  end if;

  -- All validations are complete. The following inserts run in this single database transaction.
  for v_fto in select value from jsonb_array_elements(p_payload->'ftos')
  loop
    v_fto_number := v_fto->>'ftoNumber';
    insert into public.vbgramg_fto_batches(
      fto_number, contribution_period, ledger_charge_period, village_scope,
      last_source_sha256, created_by, notes, period_id, revision_number
    ) values (
      v_fto_number, 'JUL26', date '2026-07-01', 'NEW SERCHHIP North',
      nullif(p_payload#>>'{previewMeta,sourceSha256}',''), p_actor,
      'Government FTO rejected-only import; no Contribution ledger charges created.',
      v_period.id, 1
    ) returning id into v_batch_id;

    for v_row in
      select value from jsonb_array_elements(v_prepared)
      where value->>'ftoNumber' = v_fto_number
    loop
      insert into public.vbgramg_fto_transactions(
        batch_id, reference_no, job_card_number, village_name, person_name,
        transaction_date, processed_date, amount_to_be_credited, credit_amount,
        calculated_charge, status, rejection_reason, ledger_entry_id, source_row,
        is_in_scope, is_current, last_seen_at
      ) values (
        v_batch_id, v_row->>'referenceNo', v_row->>'jobCardNo',
        v_row->>'villageName', v_row->>'personName',
        nullif(v_row->>'transactionDate','')::date,
        nullif(v_row->>'processedDate','')::date,
        (v_row->>'amount')::numeric, (v_row->>'creditAmount')::numeric,
        0, 'rejected', 'Rejected by DDO', null, v_row->'sourceRow',
        true, true, v_now
      )
      returning id into v_batch_id; -- overwritten below only after the history row has been written
      -- Retrieve the transaction by its unique batch/reference identity for status history.
      insert into public.vbgramg_fto_status_history(
        transaction_id, old_status, new_status, old_calculated_charge,
        new_calculated_charge, changed_by, fto_number, reference_no, note,
        new_processed_date
      )
      select t.id, null, 'rejected', null, 0, p_actor, v_fto_number,
             t.reference_no, 'Transaction first recorded from Government FTO preview import.',
             t.processed_date
      from public.vbgramg_fto_transactions t
      where t.batch_id = (select b.id from public.vbgramg_fto_batches b where b.fto_number = v_fto_number)
        and t.reference_no = v_row->>'referenceNo';

      -- Restore the batch id after the transaction insert RETURNING clause.
      select id into v_batch_id from public.vbgramg_fto_batches where fto_number = v_fto_number;
    end loop;
    v_results := v_results || jsonb_build_array(jsonb_build_object('fto_number',v_fto_number));
  end loop;

  return jsonb_build_object(
    'ok', true, 'batch_count', 3, 'transaction_count', 354,
    'status_history_count', 354, 'ledger_rows_created', 0, 'batches', v_results
  );
end;
$$;

revoke all on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) from public, anon, authenticated;
grant execute on function public.vbgramg_import_rejected_fto_batches(jsonb, uuid) to service_role;
