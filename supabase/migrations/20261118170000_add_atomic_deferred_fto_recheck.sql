-- Persist a dedicated deferred-recheck timestamp and per-FTO result summary.
alter table public.vbgramg_fto_batches
  add column if not exists last_deferred_recheck_at timestamptz,
  add column if not exists last_deferred_recheck_result jsonb;

comment on column public.vbgramg_fto_batches.last_deferred_recheck_at
  is 'Timestamp of the most recent successful full Government-table deferred recheck.';
comment on column public.vbgramg_fto_batches.last_deferred_recheck_result
  is 'Counts from the most recent successful full Government-table deferred recheck.';

-- Atomic reconciliation of already-imported Government FTO transactions.
-- Only existing Deferred (blank) transactions may change status. No transaction
-- or ledger rows are inserted, and Processed/Rejected records are immutable here.

create or replace function public.vbgramg_recheck_deferred_ftos(
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
  v_reference text;
  v_status text;
  v_processed_date date;
  v_rejection_reason text;
  v_batch_id uuid;
  v_transaction_id uuid;
  v_old_status text;
  v_old_processed_date date;
  v_existing_count integer;
  v_payload_count integer;
  v_updated integer := 0;
  v_still_deferred integer := 0;
  v_unchanged integer := 0;
  v_fto_count integer := 0;
  v_seen_ftos text[] := array[]::text[];
  v_seen_refs text[];
  v_results jsonb := '[]'::jsonb;
  v_fto_updated_start integer;
  v_fto_deferred_start integer;
  v_fto_unchanged_start integer;
  v_fto_result jsonb;
begin
  if p_payload is null
     or jsonb_typeof(p_payload) <> 'object'
     or jsonb_typeof(p_payload->'ftos') is distinct from 'array'
     or jsonb_array_length(p_payload->'ftos') = 0 then
    raise exception 'Deferred FTO recheck payload must contain a non-empty ftos array.';
  end if;

  if p_actor is null then
    raise exception 'Administrator identity is missing.';
  end if;

  select lower(u.email) into v_email
  from auth.users u
  where u.id = p_actor;

  if v_email is null or not exists (
    select 1
    from public.vbgramg_approved_users a
    where a.email = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can recheck Government FTO history.';
  end if;

  -- Serialize with the existing Government importer and FTO snapshot writer.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-government-fto-history-import', 0)
  );
  lock table public.vbgramg_fto_batches in share row exclusive mode;
  lock table public.vbgramg_fto_transactions in share row exclusive mode;

  -- Validate the complete submitted reconciliation set before changing anything.
  for v_fto in
    select e.value from jsonb_array_elements(p_payload->'ftos') as e(value)
  loop
    v_fto_number := btrim(coalesce(v_fto->>'ftoNumber', ''));
    if v_fto_number = '' then
      raise exception 'A recheck FTO number is missing.';
    end if;
    if upper(v_fto_number) = any(v_seen_ftos) then
      raise exception 'FTO % appears more than once in this recheck.', v_fto_number;
    end if;
    v_seen_ftos := array_append(v_seen_ftos, upper(v_fto_number));

    select b.id into v_batch_id
    from public.vbgramg_fto_batches b
    where upper(btrim(b.fto_number)) = upper(v_fto_number)
    for update;

    if v_batch_id is null then
      raise exception 'FTO % does not exist in imported FTO history.', v_fto_number;
    end if;

    if jsonb_typeof(v_fto->'rows') is distinct from 'array' then
      raise exception 'FTO % is missing its complete transaction reconciliation rows.', v_fto_number;
    end if;

    select count(*)::integer into v_existing_count
    from public.vbgramg_fto_transactions tx
    where tx.batch_id = v_batch_id;

    v_payload_count := jsonb_array_length(v_fto->'rows');
    if v_payload_count <> v_existing_count then
      raise exception 'FTO % reconciliation is incomplete: stored rows %, submitted matched rows %.',
        v_fto_number, v_existing_count, v_payload_count;
    end if;

    v_seen_refs := array[]::text[];
    for v_row in
      select e.value from jsonb_array_elements(v_fto->'rows') as e(value)
    loop
      v_reference := btrim(coalesce(v_row->>'referenceNo', ''));
      v_status := lower(btrim(coalesce(v_row->>'normalizedStatus', '')));

      if v_reference = '' then
        raise exception 'FTO % contains a row with a missing reference number.', v_fto_number;
      end if;
      if v_reference = any(v_seen_refs) then
        raise exception 'FTO % contains duplicate reference number %.', v_fto_number, v_reference;
      end if;
      v_seen_refs := array_append(v_seen_refs, v_reference);

      if v_status not in ('processed', 'rejected', 'blank', 'other') then
        raise exception 'FTO % has an unrecognized Government status for reference %.',
          v_fto_number, v_reference;
      end if;

      if not exists (
        select 1
        from public.vbgramg_fto_transactions tx
        where tx.batch_id = v_batch_id
          and btrim(tx.reference_no) = v_reference
      ) then
        raise exception 'FTO % reference % does not match an existing stored transaction.',
          v_fto_number, v_reference;
      end if;
    end loop;

    -- Equal row counts plus unique, existing references proves that every stored
    -- transaction for this FTO was represented exactly once in the full-table check.
    v_fto_count := v_fto_count + 1;
  end loop;

  -- Apply only Deferred -> Processed/Rejected transitions.
  for v_fto in
    select e.value from jsonb_array_elements(p_payload->'ftos') as e(value)
  loop
    v_fto_number := btrim(v_fto->>'ftoNumber');
    v_fto_updated_start := v_updated;
    v_fto_deferred_start := v_still_deferred;
    v_fto_unchanged_start := v_unchanged;
    select b.id into v_batch_id
    from public.vbgramg_fto_batches b
    where upper(btrim(b.fto_number)) = upper(v_fto_number);

    for v_row in
      select e.value from jsonb_array_elements(v_fto->'rows') as e(value)
    loop
      v_reference := btrim(v_row->>'referenceNo');
      v_status := lower(btrim(coalesce(v_row->>'normalizedStatus', '')));
      v_processed_date := nullif(v_row->>'processedDate', '')::date;
      v_rejection_reason := nullif(btrim(coalesce(v_row->>'rejectionReason', '')), '');

      select tx.id, tx.status, tx.processed_date
        into v_transaction_id, v_old_status, v_old_processed_date
      from public.vbgramg_fto_transactions tx
      where tx.batch_id = v_batch_id
        and btrim(tx.reference_no) = v_reference
      for update;

      if lower(btrim(coalesce(v_old_status, ''))) = 'blank'
         and v_status in ('processed', 'rejected') then
        update public.vbgramg_fto_transactions
        set status = v_status,
            processed_date = case when v_status = 'processed'
                                  then v_processed_date else processed_date end,
            rejection_reason = case when v_status = 'rejected'
                                    then v_rejection_reason else rejection_reason end,
            last_seen_at = pg_catalog.clock_timestamp(),
            updated_at = pg_catalog.clock_timestamp()
        where id = v_transaction_id;

        insert into public.vbgramg_fto_status_history (
          transaction_id, old_status, new_status,
          old_calculated_charge, new_calculated_charge,
          old_processed_date, new_processed_date,
          changed_by, fto_number, reference_no, note
        ) values (
          v_transaction_id, v_old_status, v_status,
          null, null, v_old_processed_date,
          case when v_status = 'processed' then v_processed_date else v_old_processed_date end,
          p_actor, v_fto_number, v_reference,
          'Government FTO deferred recheck: status reconciled by FTO number and reference number.'
        );
        v_updated := v_updated + 1;
      elsif lower(btrim(coalesce(v_old_status, ''))) = 'blank' then
        update public.vbgramg_fto_transactions
        set last_seen_at = pg_catalog.clock_timestamp(),
            updated_at = pg_catalog.clock_timestamp()
        where id = v_transaction_id;
        v_still_deferred := v_still_deferred + 1;
      else
        -- Processed, Rejected, and any other non-Deferred local status are immutable.
        v_unchanged := v_unchanged + 1;
      end if;
    end loop;

    v_fto_result := jsonb_build_object(
      'updated_count', v_updated - v_fto_updated_start,
      'still_deferred_count', v_still_deferred - v_fto_deferred_start,
      'unchanged_count', v_unchanged - v_fto_unchanged_start
    );

    update public.vbgramg_fto_batches
    set last_checked_at = pg_catalog.clock_timestamp(),
        last_deferred_recheck_at = pg_catalog.clock_timestamp(),
        last_deferred_recheck_result = v_fto_result
    where id = v_batch_id;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'fto_number', v_fto_number,
      'batch_id', v_batch_id,
      'result', v_fto_result
    ));
  end loop;

  return jsonb_build_object(
    'ok', true,
    'fto_count', v_fto_count,
    'updated_count', v_updated,
    'still_deferred_count', v_still_deferred,
    'unchanged_count', v_unchanged,
    'batches', v_results
  );
end;
$function$;

revoke all on function public.vbgramg_recheck_deferred_ftos(jsonb, uuid)
  from public, anon, authenticated;
grant execute on function public.vbgramg_recheck_deferred_ftos(jsonb, uuid)
  to service_role;
