-- Atomic FTO snapshot reconciliation.
-- The Edge Function performs validation and builds a complete, typed plan. This function
-- applies every FTO, history, import and ledger write in one PostgreSQL transaction.
-- No financial or FTO history rows are physically deleted.

create or replace function public.vbgramg_apply_fto_snapshot(p_plan jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_batch jsonb := p_plan->'batch';
  v_import jsonb := p_plan->'charge_import';
  v_guard record;
  v_allocated numeric(14,2);
  v_count_transactions integer := 0;
  v_count_history integer := 0;
  v_count_ledger integer := 0;
  v_count_voided integer := 0;
  v_row record;
  v_batch_id uuid;
  v_import_id uuid;
begin
  if jsonb_typeof(p_plan) <> 'object'
     or jsonb_typeof(v_batch) <> 'object'
     or jsonb_typeof(v_import) <> 'object' then
    raise exception 'Invalid FTO reconciliation plan';
  end if;

  -- Serialize imports for the same FTO and lock all affected card/period balances.
  perform pg_advisory_xact_lock(hashtextextended('fto:' || (v_batch->>'fto_number'), 0));

  for v_guard in
    select job_card_number, period_id, prospective_amount
    from jsonb_to_recordset(coalesce(p_plan->'charge_guards', '[]'::jsonb))
      as g(job_card_number text, period_id uuid, prospective_amount numeric)
    order by job_card_number, period_id
  loop
    if v_guard.prospective_amount < 0 then
      raise exception 'Invalid prospective FTO charge for %', v_guard.job_card_number;
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended('contribution:' || v_guard.job_card_number || ':' || v_guard.period_id::text, 0)
    );

    -- Lock payment rows in a stable order before reading their allocations.
    perform l.id
    from public.vbgramg_charge_ledger l
    where l.job_card_number = v_guard.job_card_number
      and l.entry_type = 'payment'
    order by l.id
    for update;

    select coalesce(sum(a.amount), 0)::numeric(14,2)
      into v_allocated
    from public.vbgramg_payment_allocations a
    join public.vbgramg_charge_ledger payment on payment.id = a.transaction_id
    where payment.job_card_number = v_guard.job_card_number
      and payment.entry_type = 'payment'
      and a.period_id = v_guard.period_id;

    if v_allocated > v_guard.prospective_amount then
      raise exception using
        message = format(
          'FTO reconciliation blocked for %s: allocated %.2f exceeds revised charge %.2f',
          v_guard.job_card_number, v_allocated, v_guard.prospective_amount
        ),
        errcode = '23514';
    end if;
  end loop;

  -- Batch identity is stable across re-imports.
  insert into public.vbgramg_fto_batches
    (id, fto_number, contribution_period, ledger_charge_period, village_scope,
     period_id, created_by, last_checked_at, last_source_sha256)
  values
    ((v_batch->>'id')::uuid, v_batch->>'fto_number',
     v_batch->>'contribution_period', (v_batch->>'ledger_charge_period')::date,
     coalesce(v_batch->>'village_scope', 'ACTIVE MIS JOB CARDS'),
     (v_batch->>'period_id')::uuid, nullif(v_batch->>'created_by','')::uuid,
     coalesce(nullif(v_batch->>'last_checked_at','')::timestamptz, now()),
     v_batch->>'last_source_sha256')
  on conflict (fto_number) do update set
    period_id = excluded.period_id,
    last_checked_at = excluded.last_checked_at,
    last_source_sha256 = excluded.last_source_sha256
  returning id into v_batch_id;

  -- Create/update transaction snapshots before writing their status-history rows.
  for v_row in
    select * from jsonb_to_recordset(coalesce(p_plan->'transactions', '[]'::jsonb)) as x(
      id uuid, batch_id uuid, reference_no text, job_card_number text, village_name text,
      person_name text, transaction_date date, amount_to_be_credited numeric,
      credit_amount numeric, calculated_charge numeric, status text, rejection_reason text,
      last_seen_at timestamptz, ledger_entry_id uuid, source_row jsonb, created_at timestamptz,
      updated_at timestamptz, is_in_scope boolean, processed_date date, is_current boolean
    )
  loop
    insert into public.vbgramg_fto_transactions
      (id,batch_id,reference_no,job_card_number,village_name,person_name,transaction_date,
       amount_to_be_credited,credit_amount,calculated_charge,status,rejection_reason,
       last_seen_at,ledger_entry_id,source_row,created_at,updated_at,is_in_scope,processed_date,is_current)
    values
      (v_row.id, v_batch_id, v_row.reference_no, v_row.job_card_number, v_row.village_name,
       v_row.person_name, v_row.transaction_date, v_row.amount_to_be_credited, v_row.credit_amount,
       v_row.calculated_charge, v_row.status, v_row.rejection_reason,
       coalesce(v_row.last_seen_at,now()), v_row.ledger_entry_id, coalesce(v_row.source_row,'{}'::jsonb),
       coalesce(v_row.created_at,now()), coalesce(v_row.updated_at,now()),
       true, v_row.processed_date, coalesce(v_row.is_current,true))
    on conflict (id) do update set
      batch_id=excluded.batch_id, reference_no=excluded.reference_no,
      job_card_number=excluded.job_card_number, village_name=excluded.village_name,
      person_name=excluded.person_name, transaction_date=excluded.transaction_date,
      amount_to_be_credited=excluded.amount_to_be_credited, credit_amount=excluded.credit_amount,
      calculated_charge=excluded.calculated_charge, status=excluded.status,
      rejection_reason=excluded.rejection_reason, last_seen_at=excluded.last_seen_at,
      source_row=excluded.source_row, updated_at=excluded.updated_at,
      is_in_scope=true, processed_date=excluded.processed_date, is_current=excluded.is_current;
    v_count_transactions := v_count_transactions + 1;
  end loop;

  insert into public.vbgramg_fto_status_history
    (transaction_id,old_status,new_status,old_calculated_charge,new_calculated_charge,
     old_processed_date,new_processed_date,changed_by,fto_number,reference_no,note)
  select transaction_id,old_status,new_status,old_calculated_charge,new_calculated_charge,
         old_processed_date,new_processed_date,changed_by,fto_number,reference_no,note
  from jsonb_to_recordset(coalesce(p_plan->'status_history', '[]'::jsonb)) as h(
    transaction_id uuid, old_status text, new_status text, old_calculated_charge numeric,
    new_calculated_charge numeric, old_processed_date date, new_processed_date date,
    changed_by uuid, fto_number text, reference_no text, note text
  );
  get diagnostics v_count_history = row_count;

  update public.vbgramg_fto_transactions
    set is_current = false, updated_at = now()
  where id = any(
    coalesce(array(select jsonb_array_elements_text(coalesce(p_plan->'omitted_transaction_ids','[]'::jsonb))::uuid), '{}'::uuid[])
  );

  -- A source hash is globally unique; re-importing the same source completes the
  -- existing import record rather than creating a duplicate.
  insert into public.vbgramg_charge_imports
    (id,source_filename,source_sha256,charge_period,row_count,total_amount,status,
     imported_by,notes,completed_at)
  values
    ((v_import->>'id')::uuid, v_import->>'source_filename', v_import->>'source_sha256',
     (v_import->>'charge_period')::date, (v_import->>'row_count')::integer,
     (v_import->>'total_amount')::numeric, 'complete',
     nullif(v_import->>'imported_by','')::uuid, v_import->>'notes',
     coalesce(nullif(v_import->>'completed_at','')::timestamptz,now()))
  on conflict (source_sha256) do update set
    row_count=excluded.row_count, total_amount=excluded.total_amount,
    status='complete', completed_at=excluded.completed_at, notes=excluded.notes
  returning id into v_import_id;

  -- Ledger writes are explicit upserts. Payment rows and allocation rows are never
  -- touched by this FTO-only operation.
  for v_row in
    select * from jsonb_to_recordset(coalesce(p_plan->'ledger_rows', '[]'::jsonb)) as x(
      id uuid, job_card_number text, person_name text, entry_type text, amount numeric,
      charge_period date, entry_date date, note text, import_id uuid, created_by uuid,
      is_deferred boolean, reference_numbers text[], applicant_name text,
      applicant_number text, applicant_unique_id text, period_id uuid,
      fto_applicant_name text, is_voided boolean
    )
  loop
    insert into public.vbgramg_charge_ledger
      (id,job_card_number,person_name,entry_type,amount,charge_period,entry_date,note,
       import_id,created_by,is_deferred,reference_numbers,applicant_name,applicant_number,
       applicant_unique_id,period_id,fto_applicant_name,is_voided)
    values
      (v_row.id,v_row.job_card_number,v_row.person_name,v_row.entry_type,v_row.amount,
       v_row.charge_period,v_row.entry_date,v_row.note,coalesce(v_import_id,v_row.import_id),v_row.created_by,
       coalesce(v_row.is_deferred,false),v_row.reference_numbers,v_row.applicant_name,
       v_row.applicant_number,v_row.applicant_unique_id,v_row.period_id,
       v_row.fto_applicant_name,coalesce(v_row.is_voided,false))
    on conflict (id) do update set
      job_card_number=excluded.job_card_number, person_name=excluded.person_name,
      amount=excluded.amount, charge_period=excluded.charge_period, entry_date=excluded.entry_date,
      note=excluded.note, import_id=coalesce(excluded.import_id,public.vbgramg_charge_ledger.import_id),
      is_deferred=excluded.is_deferred, reference_numbers=excluded.reference_numbers,
      applicant_name=coalesce(excluded.applicant_name,public.vbgramg_charge_ledger.applicant_name),
      applicant_number=coalesce(excluded.applicant_number,public.vbgramg_charge_ledger.applicant_number),
      applicant_unique_id=coalesce(excluded.applicant_unique_id,public.vbgramg_charge_ledger.applicant_unique_id),
      period_id=excluded.period_id,
      fto_applicant_name=coalesce(excluded.fto_applicant_name,public.vbgramg_charge_ledger.fto_applicant_name),
      is_voided=excluded.is_voided;
    v_count_ledger := v_count_ledger + 1;
  end loop;

  update public.vbgramg_fto_transactions tx
    set ledger_entry_id = x.ledger_entry_id, updated_at = now()
  from jsonb_to_recordset(coalesce(p_plan->'transaction_links', '[]'::jsonb))
    as x(id uuid, ledger_entry_id uuid)
  where tx.id = x.id;

  update public.vbgramg_charge_ledger
    set is_voided = true
  where id = any(
    coalesce(array(select jsonb_array_elements_text(coalesce(p_plan->'void_ledger_ids','[]'::jsonb))::uuid), '{}'::uuid[])
  );
  get diagnostics v_count_voided = row_count;

  return jsonb_build_object(
    'committed', true,
    'batch_id', v_batch_id,
    'import_id', v_import_id,
    'transactions', v_count_transactions,
    'status_history', v_count_history,
    'ledger_rows', v_count_ledger,
    'voided_ledger_rows', v_count_voided
  );
end;
$function$;

-- Allocation inserts/updates take the same card+period advisory lock as FTO
-- reconciliation. Acquire it before locking the payment row to keep lock order stable.
create or replace function public.vbgramg_validate_payment_allocation()
returns trigger
language plpgsql
security definer
set search_path = public
as $function$
declare
  tx public.vbgramg_charge_ledger%rowtype;
  already_allocated numeric(12,2);
  period_card text;
begin
  perform pg_advisory_xact_lock(
    hashtextextended('contribution:' || new.job_card_number || ':' || new.period_id::text, 0)
  );

  select * into tx
  from public.vbgramg_charge_ledger
  where id = new.transaction_id
  for update;

  if not found then raise exception 'Transaction not found'; end if;
  if tx.entry_type <> 'payment' then
    raise exception 'Only payment transactions can receive payment allocations';
  end if;
  if tx.job_card_number <> new.job_card_number then
    raise exception 'Allocation job card must match the payment transaction';
  end if;

  select coalesce(sum(amount), 0) into already_allocated
  from public.vbgramg_payment_allocations
  where transaction_id = new.transaction_id
    and id is distinct from new.id;

  if already_allocated + new.amount > tx.amount then
    raise exception 'Allocations cannot exceed the original payment amount';
  end if;

  select job_card_number into period_card
  from public.vbgramg_charge_ledger
  where period_id = new.period_id
    and entry_type in ('charge','other_charge','sanitationFee')
    and job_card_number = new.job_card_number
  limit 1;

  if period_card is null then
    raise exception 'This job card has no charge recorded for the selected period';
  end if;

  new.updated_at := now();
  return new;
end;
$function$;

revoke all on function public.vbgramg_apply_fto_snapshot(jsonb) from public, anon, authenticated;
grant execute on function public.vbgramg_apply_fto_snapshot(jsonb) to service_role;
