-- Serialize exemption changes with atomic FTO snapshot writes and revalidate
-- immutable first-seen eligibility inside the financial transaction.

create or replace function public.vbgramg_apply_fto_snapshot(p_plan jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_batch jsonb := p_plan->'batch';
  v_import jsonb := p_plan->'charge_import';
  v_guard record;
  v_allocated numeric(14,2);
  v_manual_charges numeric(14,2);
  v_total_prospective numeric(14,2);
  v_count_transactions integer := 0;
  v_count_history integer := 0;
  v_count_ledger integer := 0;
  v_count_voided integer := 0;
  v_row record;
  v_batch_id uuid;
  v_import_id uuid;
  v_manual_link_ids uuid[] := coalesce(
    array(select jsonb_array_elements_text(coalesce(p_plan->'manual_charge_link_ids','[]'::jsonb))::uuid),
    '{}'::uuid[]
  );
begin
  if jsonb_typeof(p_plan) <> 'object'
     or jsonb_typeof(v_batch) <> 'object'
     or jsonb_typeof(v_import) <> 'object' then
    raise exception 'Invalid FTO reconciliation plan';
  end if;

  if jsonb_typeof(coalesce(p_plan->'manual_charge_link_ids','[]'::jsonb)) <> 'array' then
    raise exception 'manual_charge_link_ids must be an array';
  end if;

  -- Explicit manual-to-FTO links are opt-in. A manual row may only be converted
  -- when its ID is named by the review decision and it belongs to this card/period.
  if exists (
    select 1
    from unnest(v_manual_link_ids) as linked(id)
    join public.vbgramg_charge_ledger existing on existing.id = linked.id
    join jsonb_to_recordset(coalesce(p_plan->'ledger_rows','[]'::jsonb))
      as lr(id uuid, job_card_number text, period_id uuid, charge_period date, entry_type text, note text)
      on lr.id = linked.id
    where existing.entry_type not in ('charge', 'other_charge')
      or upper(left(coalesce(existing.note,''),3)) = 'FTO'
      or existing.job_card_number is distinct from lr.job_card_number
      or lr.entry_type <> 'charge'
      or (existing.period_id is not null and existing.period_id is distinct from lr.period_id)
      or (existing.period_id is null and existing.charge_period is distinct from lr.charge_period)
  ) then
    raise exception 'An explicitly linked manual charge must be a non-FTO charge for the same job card and contribution period';
  end if;

  if exists (
    select 1 from unnest(v_manual_link_ids) as linked(id)
    where not exists (select 1 from public.vbgramg_charge_ledger l where l.id = linked.id)
  ) then
    raise exception 'An approved manual charge link refers to a missing ledger record';
  end if;

  if exists (
    select 1 from unnest(v_manual_link_ids) as linked(id)
    where not exists (
      select 1 from jsonb_to_recordset(coalesce(p_plan->'ledger_rows','[]'::jsonb))
        as lr(id uuid)
      where lr.id = linked.id
    )
  ) then
    raise exception 'Every approved manual charge link must have a corresponding ledger update';
  end if;

  -- Serialize every FTO write against exemption changes for each affected card.
  -- Acquire card locks in lexical order before the existing card/period locks.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('contribution-card:' || cards.job_card_number, 0)
  )
  from (
    select distinct pg_catalog.btrim(card) as job_card_number
    from (
      select x.job_card_number as card
      from jsonb_to_recordset(coalesce(p_plan->'transactions','[]'::jsonb))
        as x(job_card_number text)
      union all
      select x.job_card_number
      from jsonb_to_recordset(coalesce(p_plan->'ledger_rows','[]'::jsonb))
        as x(job_card_number text)
      union all
      select x.job_card_number
      from jsonb_to_recordset(coalesce(p_plan->'charge_guards','[]'::jsonb))
        as x(job_card_number text)
    ) affected
    where nullif(pg_catalog.btrim(card),'') is not null
  ) cards
  order by cards.job_card_number;

  -- Recheck first-seen eligibility inside this transaction, after acquiring
  -- the same per-card lock used by the exemption RPC. Existing created_at wins.
  if exists (
    select 1
    from jsonb_to_recordset(coalesce(p_plan->'transactions','[]'::jsonb))
      as tx(id uuid, job_card_number text, reference_no text, created_at timestamptz, is_in_scope boolean)
    left join public.vbgramg_fto_transactions existing on existing.id = tx.id
    join public.vbgramg_contribution_exemption_history h
      on h.job_card_number = pg_catalog.btrim(tx.job_card_number)
     and coalesce(existing.created_at, tx.created_at, transaction_timestamp()) >= h.started_at
     and coalesce(existing.created_at, tx.created_at, transaction_timestamp()) < coalesce(h.ended_at, 'infinity'::timestamptz)
    where coalesce(tx.is_in_scope,true)
      and exists (
        select 1
        from jsonb_to_recordset(coalesce(p_plan->'ledger_rows','[]'::jsonb))
          as lr(job_card_number text, reference_numbers text[])
        where pg_catalog.btrim(lr.job_card_number) = pg_catalog.btrim(tx.job_card_number)
          and tx.reference_no = any(coalesce(lr.reference_numbers, '{}'::text[]))
      )
  ) then
    raise exception using
      message = 'FTO snapshot rejected: a transaction was first seen during a contribution exemption interval; refresh the FTO preview before importing',
      errcode = '23514';
  end if;

  -- Serialize imports for the same FTO and lock all affected card/period balances.
  perform pg_advisory_xact_lock(hashtextextended('fto:' || (v_batch->>'fto_number'), 0));

  for v_guard in
    select job_card_number, period_id, prospective_fto_amount
    from jsonb_to_recordset(coalesce(p_plan->'charge_guards', '[]'::jsonb))
      as g(job_card_number text, period_id uuid, prospective_fto_amount numeric)
    order by job_card_number, period_id
  loop
    if nullif(v_guard.job_card_number, '') is null
       or v_guard.period_id is null
       or v_guard.prospective_fto_amount is null
       or v_guard.prospective_fto_amount < 0 then
      raise exception 'Invalid prospective FTO charge guard';
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended('contribution:' || v_guard.job_card_number || ':' || v_guard.period_id::text, 0)
    );

    -- Lock payment rows in a stable order before reading their allocations.
    perform l.id
    from public.vbgramg_charge_ledger l
    where l.job_card_number = v_guard.job_card_number
      and l.entry_type in ('payment', 'charge', 'other_charge')
      and (
        l.entry_type = 'payment'
        or l.period_id = v_guard.period_id
        or (l.period_id is null and l.charge_period = (v_batch->>'ledger_charge_period')::date)
      )
    order by l.id
    for update;

    select coalesce(sum(a.amount), 0)::numeric(14,2)
      into v_allocated
    from public.vbgramg_payment_allocations a
    join public.vbgramg_charge_ledger payment on payment.id = a.transaction_id
    where payment.job_card_number = v_guard.job_card_number
      and payment.entry_type = 'payment'
      and a.period_id = v_guard.period_id;

    -- Preserve every non-FTO charge already recorded for this card and period.
    -- The caller supplies only the prospective FTO component; historical/manual
    -- charges remain independent ledger rows and are included in the safety ceiling.
    select coalesce(sum(l.amount), 0)::numeric(14,2)
      into v_manual_charges
    from public.vbgramg_charge_ledger l
    where l.job_card_number = v_guard.job_card_number
      and (
        l.period_id = v_guard.period_id
        or (l.period_id is null and l.charge_period = (v_batch->>'ledger_charge_period')::date)
      )
      and l.entry_type in ('charge', 'other_charge')
      and coalesce(l.is_deferred, false) = false
      and coalesce(l.is_voided, false) = false
      and (upper(left(coalesce(l.note, ''), 3)) <> 'FTO' or upper(left(coalesce(l.note, ''), 9)) = 'FTO EXTRA')
      and not (l.id = any(v_manual_link_ids));

    v_total_prospective := v_manual_charges + v_guard.prospective_fto_amount;

    if v_allocated > v_total_prospective then
      raise exception using
        message = format(
          'FTO reconciliation blocked for %s: allocated %.2f exceeds revised eligible charges %.2f (manual %.2f + FTO %.2f)',
          v_guard.job_card_number, v_allocated, v_total_prospective,
          v_manual_charges, v_guard.prospective_fto_amount
        ),
        errcode = '23514';
    end if;
  end loop;

  -- Never silently move an existing FTO to another contribution period or ledger month.
  -- Such a move must use the dedicated Change Period workflow.
  if exists (
    select 1
    from public.vbgramg_fto_batches b
    where b.fto_number = v_batch->>'fto_number'
      and (
        b.period_id is distinct from (v_batch->>'period_id')::uuid
        or b.contribution_period is distinct from (v_batch->>'contribution_period')
        or b.ledger_charge_period is distinct from (v_batch->>'ledger_charge_period')::date
      )
  ) then
    raise exception 'This FTO number is already assigned to a different contribution period. Use Change Period before importing it again.';
  end if;

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
       coalesce(v_row.is_in_scope,true), v_row.processed_date, coalesce(v_row.is_current,true))
    on conflict (id) do update set
      batch_id=excluded.batch_id, reference_no=excluded.reference_no,
      job_card_number=excluded.job_card_number, village_name=excluded.village_name,
      person_name=excluded.person_name, transaction_date=excluded.transaction_date,
      amount_to_be_credited=excluded.amount_to_be_credited, credit_amount=excluded.credit_amount,
      calculated_charge=excluded.calculated_charge, status=excluded.status,
      rejection_reason=excluded.rejection_reason, last_seen_at=excluded.last_seen_at,
      source_row=excluded.source_row, updated_at=excluded.updated_at,
      is_in_scope=excluded.is_in_scope, processed_date=excluded.processed_date, is_current=excluded.is_current;
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
  where batch_id = v_batch_id
    and id = any(
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

  -- Preserve a before/after audit record whenever an existing manual charge
  -- is deliberately linked to an FTO. The original ledger ID is retained.
  insert into public.vbgramg_ledger_audit
    (ledger_entry_id,job_card_number,action,actor_user_id,before_data,after_data)
  select existing.id,existing.job_card_number,'manual_charge_linked_to_fto',
         nullif(v_batch->>'created_by','')::uuid,to_jsonb(existing),to_jsonb(lr)
  from unnest(v_manual_link_ids) as linked(id)
  join public.vbgramg_charge_ledger existing on existing.id=linked.id
  join jsonb_to_recordset(coalesce(p_plan->'ledger_rows','[]'::jsonb))
    as lr(id uuid,job_card_number text,person_name text,entry_type text,amount numeric,
          charge_period date,entry_date date,note text,import_id uuid,created_by uuid,
          is_deferred boolean,reference_numbers text[],applicant_name text,
          applicant_number text,applicant_unique_id text,period_id uuid,
          fto_applicant_name text,is_voided boolean) on lr.id=linked.id;

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
      entry_type=excluded.entry_type,
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

-- Exemption changes use the same lock namespace as FTO snapshot reconciliation.
create or replace function public.vbgramg_set_contribution_exemption(
  p_job_card_number text,
  p_exempt boolean,
  p_note text,
  p_actor_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_card text := pg_catalog.btrim(coalesce(p_job_card_number, ''));
  v_now timestamptz := clock_timestamp();
  v_history_id uuid;
begin
  if v_card = '' or pg_catalog.length(v_card) > 100 then
    raise exception 'A valid full job card number is required';
  end if;
  if p_exempt is null then raise exception 'Exemption state is required'; end if;
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('contribution-card:' || v_card, 0)
  );
  if p_exempt then
    insert into public.vbgramg_contribution_exemptions
      (job_card_number,note,created_by,updated_at)
    values (v_card,pg_catalog.left(pg_catalog.btrim(coalesce(p_note,'')),300),p_actor_user_id,v_now)
    on conflict (job_card_number) do update
      set note=excluded.note,updated_at=excluded.updated_at;
    select h.id into v_history_id from public.vbgramg_contribution_exemption_history h
    where h.job_card_number=v_card and h.ended_at is null
    order by h.started_at desc limit 1;
    if v_history_id is null then
      insert into public.vbgramg_contribution_exemption_history
        (job_card_number,note,started_at,created_by)
      values (v_card,pg_catalog.left(pg_catalog.btrim(coalesce(p_note,'')),300),v_now,p_actor_user_id)
      returning id into v_history_id;
    end if;
  else
    update public.vbgramg_contribution_exemption_history
      set ended_at=v_now,ended_by=p_actor_user_id,updated_at=v_now
    where job_card_number=v_card and ended_at is null;
    delete from public.vbgramg_contribution_exemptions where job_card_number=v_card;
  end if;
  return pg_catalog.jsonb_build_object('ok',true,'job_card_number',v_card,'exempt',p_exempt,'history_id',v_history_id,'changed_at',v_now);
end;
$function$;
revoke all on function public.vbgramg_set_contribution_exemption(text,boolean,text,uuid) from public,anon,authenticated;
grant execute on function public.vbgramg_set_contribution_exemption(text,boolean,text,uuid) to service_role;
