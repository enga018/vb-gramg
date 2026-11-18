-- Atomically revise the CO formula for one imported FTO batch.
-- Existing payment/waiver allocations are preserved. The operation fails closed
-- if the revised charges can no longer support current allocations.

create or replace function public.vbgramg_apply_fto_co_revision(
  p_batch_id uuid,
  p_expected_revision_number integer,
  p_divisor numeric,
  p_multiplier numeric,
  p_revision_reason text,
  p_actor_user_id uuid,
  p_actor_email text default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_initial_batch public.vbgramg_fto_batches%rowtype;
  v_batch public.vbgramg_fto_batches%rowtype;
  v_tx public.vbgramg_fto_transactions%rowtype;
  v_ledger public.vbgramg_charge_ledger%rowtype;
  v_period public.vbgramg_periods%rowtype;
  v_cards text[];
  v_card text;
  v_before jsonb;
  v_after jsonb;
  v_old_total numeric(14,2) := 0;
  v_new_total numeric(14,2) := 0;
  v_old_card_total numeric(14,2);
  v_new_card_total numeric(14,2);
  v_allocated numeric(14,2);
  v_waived numeric(14,2);
  v_non_fto numeric(14,2);
  v_charge_allocated numeric(14,2);
  v_new_charge numeric(14,2);
  v_affected integer := 0;
  v_updated_ledger integer := 0;
  v_revision integer;
begin
  if p_batch_id is null or p_expected_revision_number is null or p_actor_user_id is null then
    raise exception 'FTO batch, expected revision, and actor are required' using errcode = '22023';
  end if;
  if p_divisor is null or p_multiplier is null
     or p_divisor <= 0 or p_multiplier <= 0
     or p_divisor::text in ('NaN','Infinity','-Infinity')
     or p_multiplier::text in ('NaN','Infinity','-Infinity')
     or p_divisor <> trunc(p_divisor) or p_multiplier <> trunc(p_multiplier)
     or p_divisor > 1000000000 or p_multiplier > 1000000 then
    raise exception 'Divisor and multiplier must be whole positive numbers within the allowed range' using errcode = '22023';
  end if;
  if nullif(pg_catalog.btrim(coalesce(p_revision_reason,'')),'') is null
     or pg_catalog.length(pg_catalog.btrim(p_revision_reason)) > 500 then
    raise exception 'Enter a revision reason of 1–500 characters' using errcode = '22023';
  end if;

  select * into v_initial_batch
  from public.vbgramg_fto_batches
  where id = p_batch_id;
  if not found then
    raise exception 'The selected FTO batch was not found' using errcode = 'P0002';
  end if;
  if v_initial_batch.period_id is null or v_initial_batch.ledger_charge_period is null then
    raise exception 'This FTO has no unambiguous contribution period. Correct its period before changing CO calculation' using errcode = '23514';
  end if;

  select coalesce(array_agg(card order by card), '{}'::text[])
    into v_cards
  from (
    select distinct pg_catalog.btrim(job_card_number) as card
    from public.vbgramg_fto_transactions
    where batch_id = p_batch_id and is_current = true and is_in_scope = true
  ) cards;
  if cardinality(v_cards) = 0 then
    raise exception 'This FTO has no current in-scope transactions' using errcode = '23514';
  end if;

  -- Follow the same lock ordering as contribution writes and FTO period changes.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('contribution-card:' || c.card, 0)
  )
  from unnest(v_cards) as c(card)
  order by c.card;

  for v_card in select unnest(v_cards) order by 1 loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('contribution:' || v_card || ':' || v_initial_batch.period_id::text, 0)
    );
  end loop;

  -- Lock the existing round after card/round advisory locks and before the batch,
  -- matching the lock order used by FTO Change Period.
  select * into v_period
  from public.vbgramg_periods
  where id = v_initial_batch.period_id
  for update;
  if not found or v_period.contribution_month is distinct from v_initial_batch.ledger_charge_period then
    raise exception 'The FTO contribution period no longer matches its saved month' using errcode = '23514';
  end if;

  select * into v_batch
  from public.vbgramg_fto_batches
  where id = p_batch_id
  for update;
  if not found then
    raise exception 'The selected FTO batch no longer exists' using errcode = 'P0002';
  end if;
  if v_batch.revision_number is distinct from p_expected_revision_number then
    raise exception 'This FTO was revised by another operation. Reload the history and preview again' using errcode = '40001';
  end if;
  if v_batch.period_id is distinct from v_initial_batch.period_id
     or v_batch.ledger_charge_period is distinct from v_initial_batch.ledger_charge_period then
    raise exception 'The FTO period changed concurrently. Reload history and try again' using errcode = '40001';
  end if;
  perform tx.id
  from public.vbgramg_fto_transactions tx
  where tx.batch_id = p_batch_id and tx.is_current = true and tx.is_in_scope = true
  order by tx.job_card_number, tx.id
  for update;

  if exists (
    select 1
    from public.vbgramg_fto_transactions tx
    where tx.batch_id = p_batch_id and tx.is_current = true and tx.is_in_scope = true
    group by pg_catalog.upper(pg_catalog.btrim(tx.job_card_number))
    having count(*) > 1
  ) then
    raise exception 'This FTO contains multiple current transactions for one Job Card. Resolve the duplicate before changing CO calculation' using errcode = '23514';
  end if;

  v_before := public.vbgramg_get_fto_revision_snapshot(p_batch_id, null);
  if jsonb_array_length(coalesce(v_before->'unlinked_legacy_waivers','[]'::jsonb)) > 0 then
    raise exception 'This FTO affects a Job Card with an unlinked legacy waiver. Resolve the waiver before changing CO calculation' using errcode = '23514';
  end if;

  select coalesce(sum(coalesce(l.amount,0)),0)::numeric(14,2)
    into v_old_total
  from public.vbgramg_fto_transactions tx
  join public.vbgramg_charge_ledger l on l.id = tx.ledger_entry_id
  where tx.batch_id = p_batch_id and tx.is_current = true and tx.is_in_scope = true
    and tx.status in ('blank','processed');

  for v_tx in
    select *
    from public.vbgramg_fto_transactions
    where batch_id = p_batch_id and is_current = true and is_in_scope = true
    order by job_card_number, id
  loop
    v_affected := v_affected + 1;
    v_new_charge := 0;

    if v_tx.status in ('blank','processed') then
      if v_tx.credit_amount is null or v_tx.credit_amount <= 0 then
        raise exception 'FTO transaction % has no valid Credit Amount' , v_tx.reference_no using errcode = '23514';
      end if;
      v_new_charge := round((v_tx.credit_amount / p_divisor) * p_multiplier, 2);
      if v_new_charge <= 0 or v_new_charge > 10000000 then
        raise exception 'The revised CO amount for reference % is outside the allowed range', v_tx.reference_no using errcode = '23514';
      end if;

      if v_tx.ledger_entry_id is null then
        -- An unlinked eligible row is allowed only when its original import was
        -- covered by a recorded exemption interval. Do not create a new charge.
        if not exists (
          select 1
          from public.vbgramg_contribution_exemption_history h
          where h.job_card_number = v_tx.job_card_number
            and v_tx.created_at >= h.started_at
            and v_tx.created_at < coalesce(h.ended_at,'infinity'::timestamptz)
        ) then
          raise exception 'Eligible FTO transaction % has no linked charge and no exemption evidence',v_tx.reference_no using errcode = '23514';
        end if;
      else
        select * into v_ledger
        from public.vbgramg_charge_ledger
        where id = v_tx.ledger_entry_id
        for update;
        if not found
           or v_ledger.job_card_number is distinct from v_tx.job_card_number
           or v_ledger.entry_type <> 'charge'
           or coalesce(v_ledger.is_voided,false) then
          raise exception 'The linked contribution charge for reference % is missing, voided, or inconsistent',v_tx.reference_no using errcode = '23514';
        end if;
        if v_ledger.period_id is distinct from v_batch.period_id then
          raise exception 'The linked contribution charge for reference % is not in the FTO batch period',v_tx.reference_no using errcode = '23514';
        end if;

        v_old_card_total := v_ledger.amount;
        update public.vbgramg_charge_ledger
        set amount = v_new_charge
        where id = v_ledger.id;

        insert into public.vbgramg_ledger_audit
          (ledger_entry_id,job_card_number,action,actor_user_id,before_data,after_data)
        values
          (v_ledger.id,v_tx.job_card_number,'fto_co_calculation_revised',p_actor_user_id,
           pg_catalog.to_jsonb(v_ledger),
           pg_catalog.jsonb_build_object(
             'amount',v_new_charge,
             'fto_batch_id',p_batch_id,
             'reference_no',v_tx.reference_no,
             'divisor',p_divisor,
             'multiplier',p_multiplier,
             'revision_number',v_batch.revision_number + 1
           ));
        v_new_total := v_new_total + v_new_charge;
        v_updated_ledger := v_updated_ledger + 1;
      end if;
    elsif v_tx.status in ('rejected','other') then
      if v_tx.ledger_entry_id is not null then
        raise exception 'Rejected or other FTO transaction % unexpectedly has a linked contribution charge',v_tx.reference_no using errcode = '23514';
      end if;
    else
      raise exception 'FTO transaction % has an unsupported status',v_tx.reference_no using errcode = '23514';
    end if;

    update public.vbgramg_fto_transactions
    set calculated_charge = v_new_charge,
        updated_at = pg_catalog.clock_timestamp()
    where id = v_tx.id;
  end loop;

  -- Existing allocations are intentionally not rewritten. Verify each affected
  -- card still has enough eligible charges to support every committed allocation.
  for v_card in select unnest(v_cards) order by 1 loop
    select coalesce(sum(tx.calculated_charge),0)::numeric(14,2)
      into v_new_card_total
    from public.vbgramg_fto_transactions tx
    where tx.batch_id = p_batch_id
      and tx.job_card_number = v_card
      and tx.is_current = true and tx.is_in_scope = true
      and tx.status in ('blank','processed')
      and tx.ledger_entry_id is not null;

    select coalesce(sum(a.amount),0)::numeric(14,2)
      into v_allocated
    from public.vbgramg_payment_allocations a
    join public.vbgramg_charge_ledger payment on payment.id = a.transaction_id
    where a.job_card_number = v_card
      and a.period_id = v_batch.period_id
      and payment.entry_type = 'payment'
      and coalesce(payment.is_voided,false) = false;

    select coalesce(sum(w.amount),0)::numeric(14,2)
      into v_waived
    from public.vbgramg_waiver_period_allocations w
    join public.vbgramg_charge_ledger waiver on waiver.id = w.waiver_id
    where w.job_card_number = v_card
      and w.period_id = v_batch.period_id
      and waiver.entry_type in ('charge_waiver','forgive')
      and coalesce(waiver.is_voided,false) = false;

    select coalesce(sum(l.amount),0)::numeric(14,2)
      into v_non_fto
    from public.vbgramg_charge_ledger l
    where l.job_card_number = v_card
      and (l.period_id = v_batch.period_id
        or (l.period_id is null and l.charge_period = v_batch.ledger_charge_period))
      and l.entry_type in ('charge','other_charge')
      and coalesce(l.is_deferred,false) = false
      and coalesce(l.is_voided,false) = false
      and (
        pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),3)) <> 'FTO'
        or pg_catalog.upper(pg_catalog.left(pg_catalog.btrim(coalesce(l.note,'')),9)) = 'FTO EXTRA'
      );

    if v_allocated + v_waived > v_non_fto + v_new_card_total then
      raise exception 'CO revision blocked for Job Card %: allocated and waived amount %.2f exceeds revised eligible charges %.2f',
        v_card,v_allocated+v_waived,v_non_fto+v_new_card_total using errcode = '23514';
    end if;

    select coalesce(sum(a.amount),0)::numeric(14,2)
      into v_charge_allocated
    from public.vbgramg_charge_payment_allocations a
    join public.vbgramg_fto_transactions tx on tx.ledger_entry_id = a.charge_id
    where tx.batch_id = p_batch_id and tx.job_card_number = v_card
      and tx.is_current = true and tx.is_in_scope = true;

    if v_charge_allocated > v_new_card_total then
      raise exception 'CO revision blocked for Job Card %: charge-level allocations %.2f exceed revised CO charge %.2f',
        v_card,v_charge_allocated,v_new_card_total using errcode = '23514';
    end if;
  end loop;

  update public.vbgramg_fto_batches
  set calculation_divisor = p_divisor,
      calculation_multiplier = p_multiplier,
      revision_number = revision_number + 1,
      last_checked_at = pg_catalog.clock_timestamp()
  where id = p_batch_id
  returning * into v_batch;

  v_after := public.vbgramg_get_fto_revision_snapshot(p_batch_id, null);

  insert into public.vbgramg_fto_revision_history
    (batch_id,revision_number,revision_reason,actor_user_id,actor_email,
     old_period_id,new_period_id,old_contribution_period,new_contribution_period,
     old_calculation_divisor,new_calculation_divisor,
     old_calculation_multiplier,new_calculation_multiplier,
     affected_transaction_count,old_eligible_total,new_eligible_total,
     before_snapshot,after_snapshot)
  values
    (p_batch_id,v_batch.revision_number,pg_catalog.btrim(p_revision_reason),
     p_actor_user_id,nullif(pg_catalog.btrim(coalesce(p_actor_email,'')),''),
     v_batch.period_id,v_batch.period_id,
     v_batch.contribution_period,v_batch.contribution_period,
     v_initial_batch.calculation_divisor,p_divisor,
     v_initial_batch.calculation_multiplier,p_multiplier,
     v_affected,v_old_total,v_new_total,v_before,v_after);

  return pg_catalog.jsonb_build_object(
    'ok',true,'unchanged',false,'batch_id',p_batch_id,
    'revision_number',v_batch.revision_number,
    'transactions_changed',v_affected,
    'ledger_updated',v_updated_ledger,
    'old_eligible_total',v_old_total,
    'new_eligible_total',v_new_total,
    'allocations_preserved',true,
    'old_divisor',v_initial_batch.calculation_divisor,
    'new_divisor',p_divisor,
    'old_multiplier',v_initial_batch.calculation_multiplier,
    'new_multiplier',p_multiplier
  );
end;
$function$;

revoke all on function public.vbgramg_apply_fto_co_revision(uuid,integer,numeric,numeric,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.vbgramg_apply_fto_co_revision(uuid,integer,numeric,numeric,text,uuid,text)
  to service_role;

comment on function public.vbgramg_apply_fto_co_revision(uuid,integer,numeric,numeric,text,uuid,text) is
  'Atomically recalculates one imported FTO batch from saved Government Credit Amount values, updates linked FTO charges, preserves payment allocations, blocks unsupported allocations, and records before/after revision evidence.';
