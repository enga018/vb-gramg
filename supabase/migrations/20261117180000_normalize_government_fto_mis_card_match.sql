-- Normalize Job Card comparison using the same trim + uppercase rule as the preview matcher.
-- Recreate the import RPC with this matching correction; no existing records are modified.
-- Period-free Government FTO history import.
-- Government transactions are recorded independently of Contribution period assignment.
-- This operation never writes to vbgramg_charge_ledger or payment allocations.

alter table public.vbgramg_fto_batches
  alter column contribution_period drop not null,
  alter column village_scope drop not null;

comment on column public.vbgramg_fto_batches.contribution_period is
  'Contribution period assigned to this FTO batch. NULL means Government history has been imported but no Contribution period has been assigned.';

create or replace function public.vbgramg_import_government_fto_history(
  p_payload jsonb,
  p_actor uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
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
  v_fto_has_active_mis_match boolean;
  v_job_card_col integer;
  v_batch_count integer := 0;
  v_transaction_count integer := 0;
  v_history_count integer := 0;
  v_seen_ftos text[] := array[]::text[];
  v_seen_refs text[] := array[]::text[];
  v_now timestamptz := now();
  v_results jsonb := '[]'::jsonb;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Government FTO import payload must be a JSON object.';
  end if;
  if jsonb_typeof(p_payload->'ftos') is distinct from 'array' then
    raise exception 'Government FTO import payload must contain an ftos array.';
  end if;
  if jsonb_array_length(p_payload->'ftos') = 0 then
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

  -- Bind this import to the exact Active MIS snapshot reviewed by the caller.
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

  -- Resolve the Job Card column from the Active MIS header, matching the detail parser's header-based lookup.
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

  -- Serialize Government imports and prevent races with the existing manual FTO writer.
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

    if exists (select 1 from public.vbgramg_fto_batches b where upper(btrim(b.fto_number)) = upper(v_fto_number)) then
      raise exception 'FTO batch % already exists in FTO history. Nothing was imported.', v_fto_number;
    end if;
    if jsonb_typeof(v_fto->'rows') is distinct from 'array' then
      raise exception 'FTO % transaction rows must be an array.', v_fto_number;
    end if;
    if jsonb_array_length(v_fto->'rows') = 0 then
      raise exception 'FTO % must contain at least one transaction row.', v_fto_number;
    end if;

    v_seen_refs := array[]::text[];
    v_fto_has_active_mis_match := false;

    insert into public.vbgramg_fto_batches (
      fto_number, contribution_period, ledger_charge_period, village_scope,
      last_source_sha256, created_by, notes, period_id, revision_number
    ) values (
      v_fto_number, null, null, null,
      nullif(p_payload->>'sourceSha256',''), p_actor,
      'Government FTO history import; Contribution period not assigned; no ledger charges created.',
      null, 1
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

      if coalesce(v_row->>'ftoNumber','') <> v_fto_number
         or v_card = '' or v_reference = '' then
        raise exception 'FTO % contains a row with missing or inconsistent identity fields.', v_fto_number;
      end if;
      if v_status not in ('processed','rejected','blank','other') then
        raise exception 'FTO % contains an unrecognized Government status for reference %.', v_fto_number, v_reference;
      end if;
      if v_reference = any(v_seen_refs) then
        raise exception 'Duplicate Government reference number % in this import.', v_reference;
      end if;
      v_seen_refs := array_append(v_seen_refs, v_reference);

      if jsonb_typeof(v_row->'sourceRow') is distinct from 'array' then
        raise exception 'Government source columns must be an array for reference %.', v_reference;
      end if;
      if jsonb_array_length(v_row->'sourceRow') = 0 then
        raise exception 'Government source columns are empty for reference %.', v_reference;
      end if;
      v_source_row := v_row->'sourceRow';

      if nullif(v_row->>'amountToBeCredited','') is null
         or nullif(v_row->>'creditAmount','') is null
         or (v_row->>'amountToBeCredited') !~ '^[0-9]+(\.[0-9]+)?$'
         or (v_row->>'creditAmount') !~ '^[0-9]+(\.[0-9]+)?$' then
        raise exception 'A Government amount is missing or invalid for reference %.', v_reference;
      end if;
      v_amount := (v_row->>'amountToBeCredited')::numeric;
      v_credit := (v_row->>'creditAmount')::numeric;
      if v_amount < 0 or v_credit < 0 then
        raise exception 'A negative Government amount was found for reference %.', v_reference;
      end if;

      v_transaction_date := nullif(v_row->>'transactionDate','')::date;
      v_processed_date := nullif(v_row->>'processedDate','')::date;

      select exists (
        select 1 from public.vbgramg_mis_rows m
        where m.import_id = v_active_import_id
          and upper(btrim(coalesce(m.row_data->>v_job_card_col, ''))) = upper(btrim(v_card))
      ) into v_is_in_scope;
      if v_is_in_scope then v_fto_has_active_mis_match := true; end if;

      insert into public.vbgramg_fto_transactions (
        batch_id, reference_no, job_card_number, village_name, person_name,
        transaction_date, processed_date, amount_to_be_credited, credit_amount,
        calculated_charge, status, rejection_reason, ledger_entry_id, source_row,
        is_in_scope, is_current, last_seen_at
      ) values (
        v_batch_id, v_reference, v_card, v_village, v_person,
        v_transaction_date, v_processed_date, v_amount, v_credit,
        null, v_status, v_reason, null, v_source_row,
        v_is_in_scope, true, v_now
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

    if not v_fto_has_active_mis_match then
      raise exception 'FTO % has no transaction matching an Active MIS Job Card. It cannot be imported.', v_fto_number;
    end if;

    v_batch_count := v_batch_count + 1;
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'fto_number', v_fto_number,
      'batch_id', v_batch_id,
      'transaction_count', jsonb_array_length(v_fto->'rows')
    ));
  end loop;

  return jsonb_build_object(
    'ok', true,
    'batch_count', v_batch_count,
    'transaction_count', v_transaction_count,
    'status_history_count', v_history_count,
    'contribution_period_assigned', false,
    'ledger_rows_created', 0,
    'batches', v_results
  );
end;
$function$;

revoke all on function public.vbgramg_import_government_fto_history(jsonb, uuid)
  from public, anon, authenticated;
grant execute on function public.vbgramg_import_government_fto_history(jsonb, uuid)
  to service_role;
