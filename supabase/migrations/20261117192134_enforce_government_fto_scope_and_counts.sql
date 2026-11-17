alter table public.vbgramg_fto_batches
  add column if not exists government_transaction_count integer,
  add column if not exists unmatched_transaction_count integer;

comment on column public.vbgramg_fto_batches.government_transaction_count
  is 'Total Government FTO transaction rows, including rows outside Active MIS.';
comment on column public.vbgramg_fto_batches.unmatched_transaction_count
  is 'Government transaction rows whose Job Card Number is absent from the Active MIS at import time.';

CREATE OR REPLACE FUNCTION public.vbgramg_import_government_fto_history(p_payload jsonb, p_actor uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_email text;
  v_active_import_id uuid;
  v_mis_updated_at timestamptz;
  v_fto jsonb;
  v_row jsonb;
  v_fto_number text;
  v_batch_id uuid;
  v_transaction_id uuid;
  v_card text;
  v_reference text;
  v_person text;
  v_village text;
  v_status text;
  v_reason text;
  v_amount numeric;
  v_credit numeric;
  v_transaction_date date;
  v_processed_date date;
  v_source_row jsonb;
  v_is_in_scope boolean;
  v_job_card_col integer;
  v_government_count integer;
  v_unmatched_count integer;
  v_stored_count integer;
  v_batch_count integer := 0;
  v_transaction_count integer := 0;
  v_history_count integer := 0;
  v_government_total integer := 0;
  v_unmatched_total integer := 0;
  v_seen_ftos text[] := array[]::text[];
  v_seen_refs text[] := array[]::text[];
  v_now timestamptz := now();
  v_results jsonb := '[]'::jsonb;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Government FTO import payload must be a JSON object.';
  end if;
  if jsonb_typeof(p_payload->'ftos') is distinct from 'array'
     or jsonb_array_length(p_payload->'ftos') = 0 then
    raise exception 'Government FTO import payload must contain at least one FTO.';
  end if;
  if p_actor is null then
    raise exception 'Administrator identity is missing.';
  end if;

  select lower(u.email) into v_email
  from auth.users u
  where u.id = p_actor;

  if v_email is null or not exists (
    select 1 from public.vbgramg_approved_users a
    where a.email = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can import Government FTO history.';
  end if;

  if coalesce(p_payload->>'activeImportId','') = ''
     or coalesce(p_payload->>'misUpdatedAt','') = '' then
    raise exception 'Active MIS snapshot metadata is required.';
  end if;

  select s.active_import_id, s.updated_at
    into v_active_import_id, v_mis_updated_at
  from public.vbgramg_mis_state s
  where s.singleton = true
  for share;

  if v_active_import_id is null
     or v_active_import_id::text <> p_payload->>'activeImportId'
     or v_mis_updated_at is distinct from (p_payload->>'misUpdatedAt')::timestamptz then
    raise exception 'The active MIS changed after this Government FTO preview. Generate a fresh preview.';
  end if;

  select (h.ordinality - 1)::integer into v_job_card_col
  from public.vbgramg_mis_rows m
  cross join lateral jsonb_array_elements_text(m.row_data) with ordinality as h(value, ordinality)
  where m.import_id = v_active_import_id
    and m.row_number = 1
    and lower(regexp_replace(h.value, '[^A-Za-z0-9]+', ' ', 'g')) in ('job card number', 'jobcard number')
  limit 1;
  if v_job_card_col is null then
    raise exception 'Active MIS header does not contain a Job Card Number column.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-government-fto-history-import', 0)
  );
  lock table public.vbgramg_fto_batches in share row exclusive mode;
  lock table public.vbgramg_fto_transactions in share row exclusive mode;

  for v_fto in
    select e.value from jsonb_array_elements(p_payload->'ftos') as e(value)
  loop
    v_fto_number := btrim(coalesce(v_fto->>'ftoNumber',''));
    if v_fto_number = '' then
      raise exception 'An FTO number is missing.';
    end if;
    if upper(v_fto_number) = any(v_seen_ftos) then
      raise exception 'FTO % appears more than once in this import.', v_fto_number;
    end if;
    v_seen_ftos := array_append(v_seen_ftos, upper(v_fto_number));

    if exists (
      select 1 from public.vbgramg_fto_batches b
      where upper(btrim(b.fto_number)) = upper(v_fto_number)
    ) then
      raise exception 'FTO batch % already exists in FTO history. Nothing was imported.', v_fto_number;
    end if;

    if jsonb_typeof(v_fto->'rows') is distinct from 'array'
       or jsonb_array_length(v_fto->'rows') = 0 then
      raise exception 'FTO % must contain at least one matching transaction row.', v_fto_number;
    end if;

    if coalesce(v_fto->>'governmentTransactionCount','') !~ '^[0-9]+$'
       or coalesce(v_fto->>'unmatchedTransactionCount','') !~ '^[0-9]+$' then
      raise exception 'FTO % is missing valid Government transaction counts.', v_fto_number;
    end if;
    v_government_count := (v_fto->>'governmentTransactionCount')::integer;
    v_unmatched_count := (v_fto->>'unmatchedTransactionCount')::integer;
    v_stored_count := jsonb_array_length(v_fto->'rows');

    if v_government_count < 1 or v_unmatched_count < 0
       or v_government_count <> v_stored_count + v_unmatched_count then
      raise exception 'FTO % transaction counts are inconsistent: Government %, stored matching %, unmatched %.',
        v_fto_number, v_government_count, v_stored_count, v_unmatched_count;
    end if;

    v_seen_refs := array[]::text[];

    -- Validate every supplied row and confirm its Job Card belongs to the current Active MIS
    -- before inserting the batch or any transaction details.
    for v_row in
      select e.value from jsonb_array_elements(v_fto->'rows') as e(value)
    loop
      v_card := btrim(coalesce(v_row->>'jobCardNo',''));
      v_reference := btrim(coalesce(v_row->>'referenceNo',''));
      v_status := lower(btrim(coalesce(v_row->>'normalizedStatus','')));

      if coalesce(v_row->>'ftoNumber','') <> v_fto_number
         or v_card = '' or v_reference = '' then
        raise exception 'FTO % contains a row with missing or inconsistent identity fields.', v_fto_number;
      end if;
      if v_status not in ('processed','rejected','blank') then
        raise exception 'FTO % contains an unrecognized Government status for reference %.', v_fto_number, v_reference;
      end if;
      if v_reference = any(v_seen_refs) then
        raise exception 'Duplicate Government reference number % in FTO %.', v_reference, v_fto_number;
      end if;
      v_seen_refs := array_append(v_seen_refs, v_reference);

      if jsonb_typeof(v_row->'sourceRow') is distinct from 'array'
         or jsonb_array_length(v_row->'sourceRow') = 0 then
        raise exception 'Government source columns are missing for reference %.', v_reference;
      end if;

      if nullif(v_row->>'amountToBeCredited','') is null
         or nullif(v_row->>'creditAmount','') is null
         or (v_row->>'amountToBeCredited') !~ '^[0-9]+([.][0-9]+)?$'
         or (v_row->>'creditAmount') !~ '^[0-9]+([.][0-9]+)?$' then
        raise exception 'A Government amount is missing or invalid for reference %.', v_reference;
      end if;
      v_amount := (v_row->>'amountToBeCredited')::numeric;
      v_credit := (v_row->>'creditAmount')::numeric;
      if v_amount < 0 or v_credit < 0 then
        raise exception 'A negative Government amount was found for reference %.', v_reference;
      end if;

      select exists (
        select 1 from public.vbgramg_mis_rows m
        where m.import_id = v_active_import_id
          and upper(btrim(coalesce(m.row_data->>v_job_card_col, ''))) = upper(btrim(v_card))
      ) into v_is_in_scope;

      if not v_is_in_scope then
        raise exception 'FTO % includes out-of-scope Job Card % in its signed stored rows. Import rejected.',
          v_fto_number, v_card;
      end if;
    end loop;

    insert into public.vbgramg_fto_batches (
      fto_number, contribution_period, ledger_charge_period, village_scope,
      last_source_sha256, created_by, notes, period_id, revision_number,
      government_transaction_count, unmatched_transaction_count
    ) values (
      v_fto_number, null, null, null,
      nullif(p_payload->>'sourceSha256',''), p_actor,
      'Government FTO history import; Contribution period not assigned; no ledger charges created.',
      null, 1, v_government_count, v_unmatched_count
    ) returning id into v_batch_id;

    for v_row in
      select e.value from jsonb_array_elements(v_fto->'rows') as e(value)
    loop
      v_card := btrim(coalesce(v_row->>'jobCardNo',''));
      v_reference := btrim(coalesce(v_row->>'referenceNo',''));
      v_person := btrim(coalesce(v_row->>'personName',''));
      v_village := btrim(coalesce(v_row->>'villageName',''));
      v_status := lower(btrim(coalesce(v_row->>'normalizedStatus','')));
      v_reason := nullif(btrim(coalesce(v_row->>'rejectionReason','')), '');
      v_amount := (v_row->>'amountToBeCredited')::numeric;
      v_credit := (v_row->>'creditAmount')::numeric;
      v_transaction_date := nullif(v_row->>'transactionDate','')::date;
      v_processed_date := nullif(v_row->>'processedDate','')::date;
      v_source_row := v_row->'sourceRow';

      insert into public.vbgramg_fto_transactions (
        batch_id, reference_no, job_card_number, village_name, person_name,
        transaction_date, processed_date, amount_to_be_credited, credit_amount,
        calculated_charge, status, rejection_reason, ledger_entry_id, source_row,
        is_in_scope, is_current, last_seen_at
      ) values (
        v_batch_id, v_reference, v_card, v_village, v_person,
        v_transaction_date, v_processed_date, v_amount, v_credit,
        null, v_status, v_reason, null, v_source_row,
        true, true, v_now
      ) returning id into v_transaction_id;

      insert into public.vbgramg_fto_status_history (
        transaction_id, old_status, new_status, old_calculated_charge,
        new_calculated_charge, changed_by, fto_number, reference_no, note,
        new_processed_date
      ) values (
        v_transaction_id, null, v_status, null, null, p_actor,
        v_fto_number, v_reference,
        'Transaction first recorded from Government FTO history import; no Contribution period or charge assigned.',
        v_processed_date
      );

      v_transaction_count := v_transaction_count + 1;
      v_history_count := v_history_count + 1;
    end loop;

    v_government_total := v_government_total + v_government_count;
    v_unmatched_total := v_unmatched_total + v_unmatched_count;
    v_batch_count := v_batch_count + 1;
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'fto_number', v_fto_number,
      'batch_id', v_batch_id,
      'government_transaction_count', v_government_count,
      'stored_transaction_count', v_stored_count,
      'unmatched_transaction_count', v_unmatched_count
    ));
  end loop;

  return jsonb_build_object(
    'ok', true,
    'batch_count', v_batch_count,
    'government_transaction_count', v_government_total,
    'stored_transaction_count', v_transaction_count,
    'unmatched_transaction_count', v_unmatched_total,
    'status_history_count', v_history_count,
    'contribution_period_assigned', false,
    'ledger_rows_created', 0,
    'batches', v_results
  );
end;
$function$

