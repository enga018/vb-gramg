-- Atomic reassignment of an FTO batch to another contribution round.
-- All financial writes and transaction links commit or roll back together.

create or replace function public.vbgramg_skip_exempt_contribution_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  -- Only the service-role-only Change Period RPC sets this transaction-local flag.
  -- Normal FTO snapshot and manual ledger writes remain blocked for active exemptions.
  if pg_catalog.current_setting('app.vbgramg_allow_fto_period_rebuild', true) = 'on' then
    return new;
  end if;

  if exists (
    select 1 from public.vbgramg_contribution_exemptions e
    where pg_catalog.btrim(e.job_card_number) = pg_catalog.btrim(new.job_card_number)
  ) then
    return null;
  end if;
  return new;
end;
$function$;

create or replace function public.vbgramg_change_fto_period(
  p_batch_id uuid,
  p_period_id uuid,
  p_contribution_period text,
  p_charge_period date,
  p_actor_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_batch public.vbgramg_fto_batches%rowtype;
  v_initial_batch public.vbgramg_fto_batches%rowtype;
  v_ledger public.vbgramg_charge_ledger%rowtype;
  v_period public.vbgramg_periods%rowtype;
  v_old_period_id uuid;
  v_old_charge_period date;
  v_old_contribution_period text;
  v_cards text[];
  v_card text;
  v_round_id uuid;
  v_round_month date;
  v_ledger_id uuid;
  v_refs text[];
  v_amount numeric(14,2);
  v_name text;
  v_deferred boolean;
  v_entry_date date;
  v_allocated numeric(14,2);
  v_waived numeric(14,2);
  v_non_fto numeric(14,2);
  v_transactions integer := 0;
  v_cards_count integer := 0;
  v_voided integer := 0;
  v_inserted integer := 0;
  v_rounds uuid[];
begin
  if p_batch_id is null or p_period_id is null or p_actor_user_id is null then
    raise exception 'Batch, destination period, and actor are required' using errcode = '22023';
  end if;
  if nullif(pg_catalog.btrim(coalesce(p_contribution_period,'')), '') is null
     or p_charge_period is null
     or extract(day from p_charge_period) <> 1 then
    raise exception 'A valid contribution period and month-start charge date are required' using errcode = '22023';
  end if;

  -- Read without taking the row lock. Acquire per-card locks first to match snapshot ordering.
  select * into v_initial_batch
  from public.vbgramg_fto_batches
  where id = p_batch_id;
  if not found then
    raise exception 'The selected FTO batch was not found' using errcode = 'P0002';
  end if;

  select * into v_period
  from public.vbgramg_periods
  where id = p_period_id
  for update;
  if not found
     or v_period.contribution_month is distinct from p_charge_period
     or v_period.period_name is distinct from p_contribution_period then
    raise exception 'Select an existing shared charge round for the chosen contribution month' using errcode = '23514';
  end if;
  if v_period.status <> 'open' and v_initial_batch.period_id is distinct from p_period_id then
    raise exception 'The destination period is closed; reopen it before assigning an FTO' using errcode = '23514';
  end if;

  v_old_period_id := v_initial_batch.period_id;
  v_old_charge_period := v_initial_batch.ledger_charge_period;
  v_old_contribution_period := v_initial_batch.contribution_period;

  select coalesce(array_agg(card order by card), '{}'::text[])
    into v_cards
  from (
    select distinct pg_catalog.btrim(job_card_number) card
    from public.vbgramg_fto_transactions
    where batch_id = p_batch_id
  ) cards;

  -- Shared lock namespace with FTO snapshot and exemption interval mutations.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('contribution-card:' || c.card, 0)
  )
  from unnest(v_cards) as c(card)
  order by c.card;

  -- Serialize with contribution allocation/reconciliation for both rounds.
  v_rounds := array(select distinct x from unnest(array[v_old_period_id,p_period_id]) x where x is not null order by x);
  for v_card in select unnest(v_cards) order by 1 loop
    for v_round_id in select unnest(v_rounds) order by 1 loop
      perform pg_catalog.pg_advisory_xact_lock(
        pg_catalog.hashtextextended('contribution:' || v_card || ':' || v_round_id::text, 0)
      );
    end loop;
  end loop;

  -- Lock and re-read the batch only after acquiring the per-card locks.
  select * into v_batch from public.vbgramg_fto_batches where id = p_batch_id for update;
  if not found then raise exception 'The selected FTO batch no longer exists' using errcode = 'P0002'; end if;
  if v_batch.period_id is distinct from v_old_period_id
     or v_batch.ledger_charge_period is distinct from v_old_charge_period
     or v_batch.contribution_period is distinct from v_old_contribution_period then
    raise exception 'The FTO period changed concurrently; refresh history and try again' using errcode = '40001';
  end if;

  if v_batch.period_id = p_period_id
     and v_batch.ledger_charge_period = p_charge_period
     and v_batch.contribution_period = p_contribution_period then
    return pg_catalog.jsonb_build_object(
      'ok',true,'unchanged',true,'batch_id',p_batch_id,
      'old_period_id',v_old_period_id,'new_period_id',p_period_id,
      'transactions_changed',0,'job_cards_recalculated',0,
      'ledger_inserted',0,'ledger_voided',0
    );
  end if;

  -- Re-read and lock the complete transaction set only after acquiring shared locks.
  perform tx.id
  from public.vbgramg_fto_transactions tx
  where tx.batch_id = p_batch_id
  order by tx.job_card_number, tx.id
  for update;

  -- Reject ambiguous legacy FTO rows: without period_id, a month shared by
  -- multiple rounds cannot safely identify which round the old row belongs to.
  if exists (
    select 1
    from public.vbgramg_charge_ledger l
    join unnest(v_cards) c(card) on c.card = l.job_card_number
    where l.entry_type = 'charge'
      and coalesce(l.is_voided,false) = false
      and l.period_id is null
      and l.charge_period in (v_old_charge_period,p_charge_period)
      and pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),3)) = 'FTO'
      and pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),9)) <> 'FTO EXTRA'
      and (
        select count(*) from public.vbgramg_periods p
        where p.contribution_month = l.charge_period
      ) > 1
  ) then
    raise exception 'A legacy FTO charge has no round link in a month with multiple rounds; resolve that ledger link before changing this FTO' using errcode = '23514';
  end if;

  -- The exemption-write trigger must permit both voiding and replacement rows
  -- for this audited operation; first-seen interval checks remain authoritative.
  perform pg_catalog.set_config('app.vbgramg_allow_fto_period_rebuild','on',true);

  update public.vbgramg_fto_batches
  set period_id = p_period_id,
      contribution_period = p_contribution_period,
      ledger_charge_period = p_charge_period,
      last_checked_at = pg_catalog.clock_timestamp()
  where id = p_batch_id;

  -- Clear old links for transactions in the affected source/destination rounds.
  update public.vbgramg_fto_transactions tx
  set ledger_entry_id = null, updated_at = pg_catalog.clock_timestamp()
  where tx.job_card_number = any(v_cards)
    and exists (
      select 1
      from public.vbgramg_fto_batches b
      where b.id = tx.batch_id
        and b.period_id = any(v_rounds)
    );
  get diagnostics v_transactions = row_count;

  -- Do not supersede an FTO charge that has an unexpected downstream
  -- reference. Those workflows must be reconciled explicitly first.
  if exists (
    select 1
    from public.vbgramg_charge_ledger l
    join unnest(v_cards) c(card) on c.card = l.job_card_number
    where l.entry_type = 'charge'
      and coalesce(l.is_voided,false) = false
      and pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),3)) = 'FTO'
      and pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),9)) <> 'FTO EXTRA'
      and (
        l.period_id = any(v_rounds)
        or (l.period_id is null and l.charge_period in (v_old_charge_period,p_charge_period))
      )
      and (
        exists (select 1 from public.vbgramg_contribution_extras e where e.ledger_entry_id = l.id)
        or exists (select 1 from public.vbgramg_payment_allocations a where a.transaction_id = l.id)
        or exists (select 1 from public.vbgramg_payment_refund_reconciliations r where r.payment_id = l.id or r.refund_id = l.id)
        or exists (select 1 from public.vbgramg_waiver_period_allocations w where w.waiver_id = l.id)
      )
  ) then
    raise exception 'An affected FTO charge has a downstream financial reference; reconcile that reference before changing the FTO period'
      using errcode = '23514';
  end if;

  -- Supersede only FTO import component rows in the affected card/rounds.
  -- Manual charges and FTO EXTRA entries are deliberately excluded.
  for v_card in select unnest(v_cards) order by 1 loop
    for v_round_id in select unnest(v_rounds) order by 1 loop
      select p.contribution_month into v_round_month
      from public.vbgramg_periods p where p.id = v_round_id;

      for v_ledger in
        select l.*
        from public.vbgramg_charge_ledger l
        where l.job_card_number = v_card
          and l.entry_type = 'charge'
          and coalesce(l.is_voided,false) = false
          and pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),3)) = 'FTO'
          and pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),9)) <> 'FTO EXTRA'
          and (
            l.period_id = v_round_id
            or (
              l.period_id is null
              and l.charge_period = v_round_month
              and exists (
                select 1
                from public.vbgramg_fto_transactions tx
                join public.vbgramg_fto_batches b on b.id = tx.batch_id
                where tx.job_card_number = v_card
                  and b.period_id = v_round_id
                  and tx.reference_no = any(coalesce(l.reference_numbers,'{}'::text[]))
              )
            )
          )
        order by l.id
        for update
      loop
        insert into public.vbgramg_ledger_audit
          (ledger_entry_id,job_card_number,action,actor_user_id,before_data,after_data)
        values
          (v_ledger.id,v_card,'fto_change_period_voided',p_actor_user_id,
           pg_catalog.to_jsonb(v_ledger),
           pg_catalog.jsonb_build_object('is_voided',true,'batch_id',p_batch_id,
             'old_period_id',v_old_period_id,'new_period_id',p_period_id));
        update public.vbgramg_charge_ledger
        set is_voided = true
        where id = v_ledger.id;
        v_voided := v_voided + 1;
      end loop;

      -- Rebuild the FTO aggregate for this card and round from immutable
      -- transaction snapshots. Existing calculated_charge values are not changed.
      select
        coalesce(array_agg(distinct tx.reference_no order by tx.reference_no),'{}'::text[]),
        coalesce(sum(tx.calculated_charge),0)::numeric(14,2),
        coalesce((array_agg(tx.person_name order by tx.created_at,tx.id))[1],'Name needs review'),
        bool_and(tx.status = 'blank'),
        min(tx.processed_date) filter (where tx.status = 'processed')
      into v_refs,v_amount,v_name,v_deferred,v_entry_date
      from public.vbgramg_fto_transactions tx
      join public.vbgramg_fto_batches b on b.id = tx.batch_id
      where tx.job_card_number = v_card
        and b.period_id = v_round_id
        and tx.is_current = true
        and tx.is_in_scope = true
        and tx.status in ('blank','processed')
        and coalesce(tx.calculated_charge,0) > 0
        and not exists (
          select 1 from public.vbgramg_contribution_exemption_history h
          where h.job_card_number = tx.job_card_number
            and tx.created_at >= h.started_at
            and tx.created_at < coalesce(h.ended_at,'infinity'::timestamptz)
        );

      -- Fail closed if existing allocation commitments exceed the revised
      -- eligible FTO plus all non-FTO charges in this card/round, including zero-FTO rounds.
      select coalesce(sum(a.amount),0)::numeric(14,2)
      into v_allocated
      from public.vbgramg_payment_allocations a
      join public.vbgramg_charge_ledger payment on payment.id = a.transaction_id
      where a.job_card_number = v_card
        and a.period_id = v_round_id
        and payment.entry_type = 'payment'
        and coalesce(payment.is_voided,false) = false;

      select coalesce(sum(w.amount),0)::numeric(14,2)
      into v_waived
      from public.vbgramg_waiver_period_allocations w
      join public.vbgramg_charge_ledger waiver on waiver.id = w.waiver_id
      where w.job_card_number = v_card
        and w.period_id = v_round_id
        and waiver.entry_type in ('charge_waiver','forgive')
        and coalesce(waiver.is_voided,false) = false;

      select coalesce(sum(l.amount),0)::numeric(14,2)
      into v_non_fto
      from public.vbgramg_charge_ledger l
      where l.job_card_number = v_card
        and (l.period_id = v_round_id or (l.period_id is null and l.charge_period = v_round_month))
        and l.entry_type in ('charge','other_charge')
        and coalesce(l.is_deferred,false) = false
        and coalesce(l.is_voided,false) = false
        and (
          pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),3)) <> 'FTO'
          or pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),9)) = 'FTO EXTRA'
        );

      if v_allocated + v_waived > v_non_fto + v_amount then
        raise exception 'FTO Change Period blocked for %: allocated plus waived %.2f exceeds revised eligible charges %.2f',
          v_card,v_allocated+v_waived,v_non_fto+v_amount using errcode = '23514';
      end if;

      if v_amount > 0 then
        -- Suppress the normal active-exemption insert guard only inside this
        -- audited RPC; interval eligibility above remains authoritative.
        insert into public.vbgramg_charge_ledger
          (job_card_number,person_name,entry_type,amount,charge_period,entry_date,
           note,created_by,is_deferred,reference_numbers,period_id,is_voided)
        values
          (v_card,v_name,'charge',v_amount,v_round_month,
           case when v_deferred then null else v_entry_date end,
           'FTO import',p_actor_user_id,true,v_refs,v_round_id,false)
        returning id into v_ledger_id;

        -- Insert deferred to avoid the AFTER INSERT auto-allocation trigger.
        -- Turning deferred off does not fire the deferred-release trigger.
        update public.vbgramg_charge_ledger
        set is_deferred = coalesce(v_deferred,false)
        where id = v_ledger_id;
        v_inserted := v_inserted + 1;

        update public.vbgramg_fto_transactions tx
        set ledger_entry_id = v_ledger_id, updated_at = pg_catalog.clock_timestamp()
        from public.vbgramg_fto_batches b
        where b.id = tx.batch_id
          and tx.job_card_number = v_card
          and b.period_id = v_round_id
          and tx.is_current = true
          and tx.is_in_scope = true
          and tx.status in ('blank','processed')
          and coalesce(tx.calculated_charge,0) > 0
          and not exists (
            select 1 from public.vbgramg_contribution_exemption_history h
            where h.job_card_number = tx.job_card_number
              and tx.created_at >= h.started_at
              and tx.created_at < coalesce(h.ended_at,'infinity'::timestamptz)
          );
        insert into public.vbgramg_ledger_audit
          (ledger_entry_id,job_card_number,action,actor_user_id,before_data,after_data)
        values
          (v_ledger_id,v_card,'fto_change_period_created',p_actor_user_id,null,
           pg_catalog.jsonb_build_object('amount',v_amount,'period_id',v_round_id,
             'charge_period',v_round_month,'reference_numbers',v_refs,'is_deferred',v_deferred));
      end if;
    end loop;
    v_cards_count := v_cards_count + 1;
  end loop;

  perform pg_catalog.set_config('app.vbgramg_allow_fto_period_rebuild','off',true);

  return pg_catalog.jsonb_build_object(
    'ok',true,'unchanged',false,'batch_id',p_batch_id,
    'old_period_id',v_old_period_id,'new_period_id',p_period_id,
    'old_charge_period',v_old_charge_period,'new_charge_period',p_charge_period,
    'transactions_changed',v_transactions,'job_cards_recalculated',v_cards_count,
    'ledger_inserted',v_inserted,'ledger_voided',v_voided
  );
end;
$function$;

revoke all on function public.vbgramg_change_fto_period(uuid,uuid,text,date,uuid)
  from public, anon, authenticated;
grant execute on function public.vbgramg_change_fto_period(uuid,uuid,text,date,uuid)
  to service_role;

comment on function public.vbgramg_change_fto_period(uuid,uuid,text,date,uuid) is
  'Atomically moves an FTO batch and rebuilds affected card/round FTO ledger components while preserving ledger history and payment allocations.';
