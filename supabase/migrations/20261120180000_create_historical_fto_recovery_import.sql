-- Isolated historical Government FTO import for JAN26-JUN26.
-- This RPC intentionally does not consult Active MIS and never writes to
-- vbgramg_charge_ledger or any payment/allocation table.

create or replace function public.vbgramg_import_historical_fto_recovery(
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
  v_fto jsonb;
  v_row jsonb;
  v_fto_number text;
  v_batch_id uuid;
  v_transaction_id uuid;
  v_card text;
  v_reference text;
  v_status text;
  v_amount numeric;
  v_credit numeric;
  v_transaction_date date;
  v_processed_date date;
  v_row_count integer;
  v_seen_ftos text[] := array[]::text[];
  v_seen_refs text[];
  v_batch_count integer := 0;
  v_transaction_count integer := 0;
  v_history_count integer := 0;
  v_results jsonb := '[]'::jsonb;
  v_now timestamptz := now();
begin
  if p_payload is null or jsonb_typeof(p_payload) is distinct from 'object' then
    raise exception 'Historical FTO import requires an object payload.';
  end if;

  if jsonb_typeof(p_payload->'ftos') is distinct from 'array' then
    raise exception 'Historical FTO import requires an ftos array.';
  end if;

  if jsonb_array_length(p_payload->'ftos') = 0 then
    raise exception 'Historical FTO import requires at least one FTO.';
  end if;

  if p_actor is null then
    raise exception 'Administrator identity is required.';
  end if;

  select lower(u.email) into v_email
  from auth.users u
  where u.id = p_actor;

  if v_email is null or not exists (
    select 1
    from public.vbgramg_approved_users a
    where lower(a.email) = v_email
      and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can import historical FTOs.';
  end if;

  -- Serialize imports and prevent duplicate batch races.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-historical-fto-recovery-import', 0)
  );
  lock table public.vbgramg_fto_batches in share row exclusive mode;
  lock table public.vbgramg_fto_transactions in share row exclusive mode;

  for v_fto in
    select e.value from jsonb_array_elements(p_payload->'ftos') as e(value)
  loop
    v_fto_number := upper(btrim(coalesce(v_fto->>'ftoNumber', '')));
    if v_fto_number = '' then
      raise exception 'An FTO number is missing.';
    end if;

    if v_fto_number = any(v_seen_ftos) then
      raise exception 'FTO % appears more than once in this request.', v_fto_number;
    end if;
    v_seen_ftos := array_append(v_seen_ftos, v_fto_number);

    if exists (
      select 1 from public.vbgramg_fto_batches b
      where upper(btrim(b.fto_number)) = v_fto_number
    ) then
      raise exception 'FTO % already exists in FTO history. Nothing was imported.', v_fto_number;
    end if;

    if jsonb_typeof(v_fto->'rows') is distinct from 'array' then
      raise exception 'FTO % rows must be an array.', v_fto_number;
    end if;

    if jsonb_array_length(v_fto->'rows') = 0 then
      raise exception 'FTO % has no transaction rows.', v_fto_number;
    end if;

    v_row_count := jsonb_array_length(v_fto->'rows');
    if coalesce(v_fto->>'governmentTransactionCount', '') !~ '^[0-9]+$'
       or (v_fto->>'governmentTransactionCount')::integer <> v_row_count then
      raise exception 'FTO % Government transaction count does not match supplied rows.', v_fto_number;
    end if;

    v_seen_refs := array[]::text[];

    -- Validate the entire FTO before inserting its batch.
    for v_row in
      select e.value from jsonb_array_elements(v_fto->'rows') as e(value)
    loop
      v_card := upper(btrim(coalesce(v_row->>'jobCardNo', '')));
      v_reference := btrim(coalesce(v_row->>'referenceNo', ''));
      v_status := lower(btrim(coalesce(v_row->>'normalizedStatus', '')));

      if upper(btrim(coalesce(v_row->>'ftoNumber', ''))) <> v_fto_number
         or v_card = '' or v_reference = '' then
        raise exception 'FTO % contains a row with missing or inconsistent identity.', v_fto_number;
      end if;

      if v_status not in ('processed', 'rejected', 'blank', 'other') then
        raise exception 'FTO % has an unsupported status for reference %.', v_fto_number, v_reference;
      end if;

      if upper(v_reference) = any(v_seen_refs) then
        raise exception 'FTO % contains duplicate reference % (case-insensitive).', v_fto_number, v_reference;
      end if;
      v_seen_refs := array_append(v_seen_refs, upper(v_reference));

      if jsonb_typeof(v_row->'sourceRow') is distinct from 'array' then
        raise exception 'Government source row must be an array for reference %.', v_reference;
      end if;

      if jsonb_array_length(v_row->'sourceRow') = 0 then
        raise exception 'Government source row is empty for reference %.', v_reference;
      end if;

      if coalesce(v_row->>'amountToBeCredited', '') !~ '^[0-9]+([.][0-9]+)?$'
         or coalesce(v_row->>'creditAmount', '') !~ '^[0-9]+([.][0-9]+)?$' then
        raise exception 'Government amounts are missing or invalid for reference %.', v_reference;
      end if;

      v_amount := (v_row->>'amountToBeCredited')::numeric;
      v_credit := (v_row->>'creditAmount')::numeric;
      if v_amount < 0 or v_credit < 0 then
        raise exception 'Negative Government amount for reference %.', v_reference;
      end if;

      -- Historical scope is the JAN26-JUN26 Charge Ledger, not Active MIS.
      if not exists (
        select 1
        from public.vbgramg_charge_ledger l
        where upper(btrim(l.job_card_number)) = v_card
          and l.entry_type = 'charge'
          and coalesce(l.is_voided, false) = false
          and l.charge_period >= date '2026-01-01'
          and l.charge_period <= date '2026-06-01'
      ) then
        raise exception 'Job Card % has no non-voided JAN26-JUN26 Charge Ledger entry. FTO % was not imported.',
          v_card, v_fto_number;
      end if;

    end loop;

    -- Explicit NULL prevents the village_scope default from assigning a
    -- misleading current-village scope to historical source records.
    insert into public.vbgramg_fto_batches (
      fto_number,
      contribution_period,
      ledger_charge_period,
      village_scope,
      created_by,
      notes,
      period_id,
      revision_number,
      government_transaction_count,
      unmatched_transaction_count
    ) values (
      v_fto_number,
      null,
      null,
      null,
      p_actor,
      'Historical Government FTO recovery; period not assigned; no financial ledger changes.',
      null,
      1,
      v_row_count,
      0
    ) returning id into v_batch_id;

    for v_row in
      select e.value from jsonb_array_elements(v_fto->'rows') as e(value)
    loop
      v_card := btrim(coalesce(v_row->>'jobCardNo', ''));
      v_reference := btrim(coalesce(v_row->>'referenceNo', ''));
      v_status := lower(btrim(coalesce(v_row->>'normalizedStatus', '')));
      v_amount := (v_row->>'amountToBeCredited')::numeric;
      v_credit := (v_row->>'creditAmount')::numeric;
      v_transaction_date := nullif(v_row->>'transactionDate', '')::date;
      v_processed_date := nullif(v_row->>'processedDate', '')::date;

      insert into public.vbgramg_fto_transactions (
        batch_id,
        reference_no,
        job_card_number,
        village_name,
        person_name,
        transaction_date,
        processed_date,
        amount_to_be_credited,
        credit_amount,
        calculated_charge,
        status,
        rejection_reason,
        ledger_entry_id,
        source_row,
        is_in_scope,
        is_current,
        last_seen_at
      ) values (
        v_batch_id,
        v_reference,
        v_card,
        nullif(btrim(coalesce(v_row->>'villageName', '')), ''),
        coalesce(nullif(btrim(coalesce(v_row->>'personName', '')), ''), 'Unknown'),
        v_transaction_date,
        v_processed_date,
        v_amount,
        v_credit,
        null,
        v_status,
        nullif(btrim(coalesce(v_row->>'rejectionReason', '')), ''),
        null,
        v_row->'sourceRow',
        true,
        true,
        v_now
      ) returning id into v_transaction_id;

      insert into public.vbgramg_fto_status_history (
        transaction_id,
        old_status,
        new_status,
        old_calculated_charge,
        new_calculated_charge,
        changed_by,
        fto_number,
        reference_no,
        note,
        new_processed_date
      ) values (
        v_transaction_id,
        null,
        v_status,
        null,
        null,
        p_actor,
        v_fto_number,
        v_reference,
        'First recorded from historical Government FTO recovery; no contribution charge or payment created.',
        v_processed_date
      );

      v_transaction_count := v_transaction_count + 1;
      v_history_count := v_history_count + 1;
    end loop;

    v_batch_count := v_batch_count + 1;
    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'fto_number', v_fto_number,
      'batch_id', v_batch_id,
      'transaction_count', v_row_count
    ));
  end loop;

  return jsonb_build_object(
    'ok', true,
    'batch_count', v_batch_count,
    'transaction_count', v_transaction_count,
    'status_history_count', v_history_count,
    'ledger_rows_created', 0,
    'payment_rows_created', 0,
    'allocation_rows_created', 0,
    'ledger_links_created', 0,
    'batches', v_results
  );
end;
$function$;

revoke all on function public.vbgramg_import_historical_fto_recovery(jsonb, uuid)
  from public, anon, authenticated;
grant execute on function public.vbgramg_import_historical_fto_recovery(jsonb, uuid)
  to service_role;

comment on function public.vbgramg_import_historical_fto_recovery(jsonb, uuid)
  is 'Isolated JAN26-JUN26 historical Government FTO import. Writes only FTO batch, transaction, and status-history tables; never writes Contribution Ledger or payment allocations.';
