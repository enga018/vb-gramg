create or replace function public.vbgramg_fto_co_revision_fingerprint(p_batch_id uuid)
returns text
language plpgsql stable security definer set search_path = ''
as $function$
declare
  v_cards text[];
  v_payload jsonb;
begin
  select coalesce(array_agg(distinct pg_catalog.upper(pg_catalog.btrim(tx.job_card_number)) order by pg_catalog.upper(pg_catalog.btrim(tx.job_card_number))), '{}'::text[])
    into v_cards
  from public.vbgramg_fto_transactions tx
  where tx.batch_id=p_batch_id and tx.is_current=true and tx.is_in_scope=true;

  select pg_catalog.jsonb_build_object(
    'transactions',coalesce((
      select jsonb_agg(to_jsonb(tx) order by tx.job_card_number,tx.reference_no,tx.id)
      from public.vbgramg_fto_transactions tx where tx.batch_id=p_batch_id
    ),'[]'::jsonb),
    'ledger',coalesce((
      select jsonb_agg(to_jsonb(l) order by l.id)
      from public.vbgramg_charge_ledger l
      where pg_catalog.upper(pg_catalog.btrim(l.job_card_number))=any(v_cards)
    ),'[]'::jsonb),
    'charge_allocations',coalesce((
      select jsonb_agg(to_jsonb(a) order by a.payment_id,a.charge_id,a.allocation_source,a.id)
      from public.vbgramg_charge_payment_allocations a
      join public.vbgramg_charge_ledger pay on pay.id=a.payment_id
      join public.vbgramg_charge_ledger charge on charge.id=a.charge_id
      where pg_catalog.upper(pg_catalog.btrim(pay.job_card_number))=any(v_cards)
         or pg_catalog.upper(pg_catalog.btrim(charge.job_card_number))=any(v_cards)
    ),'[]'::jsonb),
    'legacy_allocations',coalesce((
      select jsonb_agg(to_jsonb(a) order by a.transaction_id,a.period_id,a.allocation_source,a.id)
      from public.vbgramg_payment_allocations a
      where pg_catalog.upper(pg_catalog.btrim(a.job_card_number))=any(v_cards)
    ),'[]'::jsonb),
    'refunds',coalesce((
      select jsonb_agg(to_jsonb(r) order by r.payment_id,r.id)
      from public.vbgramg_payment_refund_reconciliations r
      join public.vbgramg_charge_ledger pay on pay.id=r.payment_id
      where pg_catalog.upper(pg_catalog.btrim(pay.job_card_number))=any(v_cards)
    ),'[]'::jsonb),
    'waivers',coalesce((
      select jsonb_agg(to_jsonb(w) order by w.waiver_id,w.period_id,w.id)
      from public.vbgramg_waiver_period_allocations w
      where pg_catalog.upper(pg_catalog.btrim(w.job_card_number))=any(v_cards)
    ),'[]'::jsonb),
    'manual_charge_links',coalesce((
      select jsonb_agg(jsonb_build_object(
        'ledger_entry_id',a.ledger_entry_id,'job_card_number',a.job_card_number,
        'before_data',a.before_data,'after_data',a.after_data,'created_at',a.created_at
      ) order by a.created_at,a.id)
      from public.vbgramg_ledger_audit a
      where a.job_card_number=any(v_cards)
        and a.action='manual_charge_linked_to_fto'
        and exists (
          select 1
          from jsonb_array_elements_text(
            case when jsonb_typeof(a.after_data->'reference_numbers')='array'
              then a.after_data->'reference_numbers' else '[]'::jsonb end
          ) linked_reference
          join public.vbgramg_fto_transactions tx
            on tx.batch_id=p_batch_id and coalesce(tx.is_in_scope,true)
           and tx.reference_no=linked_reference.value
        )
    ),'[]'::jsonb),
    'periods',coalesce((
      select jsonb_agg(to_jsonb(p) order by p.contribution_month,p.period_date,p.created_at,p.id)
      from public.vbgramg_periods p
      where p.id in (
        select distinct l.period_id from public.vbgramg_charge_ledger l
        where pg_catalog.upper(pg_catalog.btrim(l.job_card_number))=any(v_cards)
          and l.period_id is not null
      )
    ),'[]'::jsonb),
    'active_exemptions',coalesce((
      select jsonb_agg(to_jsonb(e) order by e.job_card_number)
      from public.vbgramg_contribution_exemptions e
      where pg_catalog.upper(pg_catalog.btrim(e.job_card_number))=any(v_cards)
    ),'[]'::jsonb),
    'exemption_history',coalesce((
      select jsonb_agg(to_jsonb(h) order by h.job_card_number,h.started_at,h.id)
      from public.vbgramg_contribution_exemption_history h
      where pg_catalog.upper(pg_catalog.btrim(h.job_card_number))=any(v_cards)
    ),'[]'::jsonb)
  ) into v_payload;

  return pg_catalog.md5(coalesce(v_payload,'{}'::jsonb)::text);
end;
$function$;

revoke all on function public.vbgramg_fto_co_revision_fingerprint(uuid)
  from public,anon,authenticated;
grant execute on function public.vbgramg_fto_co_revision_fingerprint(uuid)
  to service_role;

-- Charge-aware FIFO simulation and atomic rebuild for CO recalculation.
-- Legacy period-level allocations remain independent, unchanged reservations.
create or replace function public.vbgramg_simulate_charge_level_fifo(
  p_charges jsonb,
  p_payments jsonb,
  p_refunds jsonb,
  p_fixed_charge_allocations jsonb,
  p_legacy_period_allocations jsonb,
  p_period_waivers jsonb,
  p_is_exempt boolean default false
) returns jsonb
language plpgsql immutable set search_path = ''
as $function$
declare
  v_period record;
  v_charge record;
  v_payment record;
  v_period_due numeric(14,2);
  v_charge_due numeric(14,2);
  v_fixed_charge numeric(14,2);
  v_legacy_period numeric(14,2);
  v_period_waived numeric(14,2);
  v_payment_fixed numeric(14,2);
  v_legacy_total numeric(14,2);
  v_period_fixed numeric(14,2);
  v_refunded numeric(14,2);
  v_allocated numeric(14,2);
  v_available numeric(14,2);
  v_take numeric(14,2);
  v_allocations jsonb := '[]'::jsonb;
  v_period_results jsonb := '[]'::jsonb;
  v_payment_results jsonb := '[]'::jsonb;
  v_fifo_total numeric(14,2) := 0;
begin
  if p_charges is null or p_payments is null or p_refunds is null
     or p_fixed_charge_allocations is null or p_legacy_period_allocations is null
     or p_period_waivers is null
     or jsonb_typeof(p_charges) <> 'array'
     or jsonb_typeof(p_payments) <> 'array'
     or jsonb_typeof(p_refunds) <> 'array'
     or jsonb_typeof(p_fixed_charge_allocations) <> 'array'
     or jsonb_typeof(p_legacy_period_allocations) <> 'array'
     or jsonb_typeof(p_period_waivers) <> 'array'
     or jsonb_array_length(p_period_waivers) > 50000
     or jsonb_array_length(p_charges) > 50000
     or jsonb_array_length(p_payments) > 10000
     or jsonb_array_length(p_refunds) > 50000
     or jsonb_array_length(p_fixed_charge_allocations) > 50000
     or jsonb_array_length(p_legacy_period_allocations) > 50000 then
    raise exception 'Charge FIFO inputs must be bounded JSON arrays';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_charges) as c(
      charge_id uuid, period_id uuid, period_order integer,
      amount numeric, charge_created_at timestamptz
    )
    where c.charge_id is null or c.period_id is null or c.period_order is null
       or c.amount is null or c.amount < 0
  ) or exists (
    select 1 from (
      select c.charge_id from jsonb_to_recordset(p_charges) as c(charge_id uuid)
      group by c.charge_id having count(*) > 1
    ) d
  ) then
    raise exception 'Invalid or duplicate allocatable charge';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_payments) as p(
      payment_id uuid, amount numeric, payment_date date, created_at timestamptz
    ) where p.payment_id is null or p.amount is null or p.amount < 0
  ) or exists (
    select 1 from (
      select p.payment_id from jsonb_to_recordset(p_payments) as p(payment_id uuid)
      group by p.payment_id having count(*) > 1
    ) d
  ) then
    raise exception 'Invalid or duplicate payment';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_refunds) as r(payment_id uuid, amount numeric)
    where r.payment_id is null or r.amount is null or r.amount < 0
  ) or exists (
    select 1 from jsonb_to_recordset(p_refunds) as r(payment_id uuid)
    left join jsonb_to_recordset(p_payments) as p(payment_id uuid)
      on p.payment_id = r.payment_id
    where p.payment_id is null
  ) then
    raise exception 'Refund references a payment outside the supplied scope';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_period_waivers) as w(period_id uuid, amount numeric)
    where w.period_id is null or w.amount is null or w.amount <= 0
  ) then
    raise exception 'Invalid period waiver allocation';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_fixed_charge_allocations) as a(
      payment_id uuid, charge_id uuid, period_id uuid, amount numeric, allocation_source text
    )
    where a.payment_id is null or a.charge_id is null or a.period_id is null
       or a.amount is null or a.amount <= 0
       or a.allocation_source not in ('manual','historical_fifo_reviewed','historical_evidence')
  ) or exists (
    select 1 from jsonb_to_recordset(p_legacy_period_allocations) as a(
      payment_id uuid, period_id uuid, amount numeric
    )
    where a.payment_id is null or a.period_id is null or a.amount is null or a.amount <= 0
  ) then
    raise exception 'Invalid fixed or legacy allocation';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_fixed_charge_allocations) as a(
      payment_id uuid, charge_id uuid, period_id uuid
    )
    left join jsonb_to_recordset(p_payments) as p(payment_id uuid)
      on p.payment_id = a.payment_id
    where p.payment_id is null
  ) or exists (
    select 1 from jsonb_to_recordset(p_fixed_charge_allocations) as a(
      payment_id uuid, charge_id uuid, period_id uuid
    )
    left join jsonb_to_recordset(p_charges) as c(charge_id uuid, period_id uuid)
      on c.charge_id = a.charge_id and c.period_id = a.period_id
    where c.charge_id is null
  ) or exists (
    select 1 from jsonb_to_recordset(p_legacy_period_allocations) as a(
      payment_id uuid, period_id uuid
    )
    left join jsonb_to_recordset(p_payments) as p(payment_id uuid)
      on p.payment_id = a.payment_id
    where p.payment_id is null
  ) or exists (
    select 1 from jsonb_to_recordset(p_legacy_period_allocations) as a(
      payment_id uuid, period_id uuid
    )
    left join jsonb_to_recordset(p_charges) as c(period_id uuid)
      on c.period_id = a.period_id
    where c.period_id is null
  ) or exists (
    select 1 from jsonb_to_recordset(p_period_waivers) as w(period_id uuid)
    left join jsonb_to_recordset(p_charges) as c(period_id uuid)
      on c.period_id=w.period_id
    where c.period_id is null
  ) then
    raise exception 'Allocation or waiver references a period outside the supplied scope';
  end if;

  -- The two allocation systems must not reserve the same payment: their historical
  -- relationship is not inferable, so counting both would risk double-reserving it.
  if exists (
    select 1
    from jsonb_to_recordset(p_fixed_charge_allocations) as c(payment_id uuid)
    join jsonb_to_recordset(p_legacy_period_allocations) as l(payment_id uuid)
      on l.payment_id = c.payment_id
  ) then
    raise exception 'A payment has both charge-level and legacy period-level allocations; resolve this ambiguous overlap before CO recalculation';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_payments) as p(payment_id uuid, amount numeric)
    left join lateral (
      select coalesce(sum(r.amount),0) total
      from jsonb_to_recordset(p_refunds) as r(payment_id uuid, amount numeric)
      where r.payment_id=p.payment_id
    ) r on true
    left join lateral (
      select coalesce(sum(a.amount),0) total
      from jsonb_to_recordset(p_fixed_charge_allocations) as a(payment_id uuid, amount numeric)
      where a.payment_id=p.payment_id
    ) c on true
    left join lateral (
      select coalesce(sum(a.amount),0) total
      from jsonb_to_recordset(p_legacy_period_allocations) as a(payment_id uuid, amount numeric)
      where a.payment_id=p.payment_id
    ) l on true
    where r.total+c.total+l.total > p.amount
  ) then
    raise exception 'Fixed allocations and refunds exceed payment capacity';
  end if;

  if exists (
    select 1 from jsonb_to_recordset(p_charges) as c(charge_id uuid, amount numeric)
    left join lateral (
      select coalesce(sum(a.amount),0) total
      from jsonb_to_recordset(p_fixed_charge_allocations) as a(charge_id uuid, amount numeric)
      where a.charge_id=c.charge_id
    ) f on true
    where f.total > c.amount
  ) then
    raise exception 'Fixed charge-level allocations exceed a revised charge balance';
  end if;

  if exists (
    select 1 from (
      select c.period_id,
        sum(c.amount) charge_total,
        coalesce(max(l.legacy_total),0) legacy_total,
        coalesce(max(f.fixed_total),0) fixed_total,
        coalesce(max(w.waived_total),0) waived_total
      from jsonb_to_recordset(p_charges) as c(period_id uuid, amount numeric)
      left join lateral (
        select sum(a.amount) legacy_total
        from jsonb_to_recordset(p_legacy_period_allocations) as a(period_id uuid, amount numeric)
        where a.period_id=c.period_id
      ) l on true
      left join lateral (
        select sum(a.amount) fixed_total
        from jsonb_to_recordset(p_fixed_charge_allocations) as a(period_id uuid, amount numeric)
        where a.period_id=c.period_id
      ) f on true
      left join lateral (
        select sum(w.amount) waived_total
        from jsonb_to_recordset(p_period_waivers) as w(period_id uuid, amount numeric)
        where w.period_id=c.period_id
      ) w on true
      group by c.period_id
    ) x where x.legacy_total+x.fixed_total+x.waived_total > x.charge_total
  ) then
    raise exception 'Fixed and legacy allocations exceed a revised period balance';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'payment_id',a.payment_id,'charge_id',a.charge_id,'period_id',a.period_id,
    'amount',a.amount,'allocation_source',a.allocation_source
  ) order by a.payment_id,a.charge_id,a.allocation_source),'[]'::jsonb)
  into v_allocations
  from jsonb_to_recordset(p_fixed_charge_allocations) as a(
    payment_id uuid, charge_id uuid, period_id uuid, amount numeric, allocation_source text
  );

  if p_is_exempt then
    return jsonb_build_object(
      'status','exempt','proposed_allocations',v_allocations,
      'preserved_legacy_period_allocations',p_legacy_period_allocations,
      'fixed_allocations_preserved',true,'fifo_allocated_total',0,
      'periods','[]'::jsonb,'payments','[]'::jsonb
    );
  end if;

  for v_period in
    select c.period_id,c.period_order,sum(c.amount)::numeric(14,2) as charge_total
    from jsonb_to_recordset(p_charges) as c(
      charge_id uuid,period_id uuid,period_order integer,amount numeric,charge_created_at timestamptz
    )
    group by c.period_id,c.period_order
    order by c.period_order,c.period_id
  loop
    select coalesce(sum(a.amount),0)::numeric(14,2)
      into v_period_fixed
    from jsonb_to_recordset(p_fixed_charge_allocations) as a(period_id uuid,amount numeric)
    where a.period_id=v_period.period_id;

    select coalesce(sum(a.amount),0)::numeric(14,2)
      into v_legacy_period
    from jsonb_to_recordset(p_legacy_period_allocations) as a(period_id uuid,amount numeric)
    where a.period_id=v_period.period_id;

    select coalesce(sum(w.amount),0)::numeric(14,2)
      into v_period_waived
    from jsonb_to_recordset(p_period_waivers) as w(period_id uuid,amount numeric)
    where w.period_id=v_period.period_id;

    v_period_due := v_period.charge_total-v_period_fixed-v_legacy_period-v_period_waived;

    for v_charge in
      select c.charge_id,c.period_id,c.amount
      from jsonb_to_recordset(p_charges) as c(
        charge_id uuid,period_id uuid,period_order integer,amount numeric,charge_created_at timestamptz
      )
      where c.period_id=v_period.period_id
      order by c.charge_created_at asc nulls last,c.charge_id
    loop
      select coalesce(sum(a.amount),0)::numeric(14,2)
        into v_fixed_charge
      from jsonb_to_recordset(p_fixed_charge_allocations) as a(charge_id uuid,amount numeric)
      where a.charge_id=v_charge.charge_id;
      v_charge_due:=v_charge.amount-v_fixed_charge;

      for v_payment in
        select p.payment_id,p.amount,p.payment_date,p.created_at
        from jsonb_to_recordset(p_payments) as p(
          payment_id uuid,amount numeric,payment_date date,created_at timestamptz
        )
        order by p.payment_date asc nulls last,p.created_at asc nulls last,p.payment_id
      loop
        select coalesce(sum(r.amount),0)::numeric(14,2)
          into v_refunded
        from jsonb_to_recordset(p_refunds) as r(payment_id uuid,amount numeric)
        where r.payment_id=v_payment.payment_id;

        select coalesce(sum(a.amount),0)::numeric(14,2)
          into v_payment_fixed
        from jsonb_to_recordset(p_fixed_charge_allocations) as a(payment_id uuid,amount numeric)
        where a.payment_id=v_payment.payment_id;

        select coalesce(sum(a.amount),0)::numeric(14,2)
          into v_legacy_total
        from jsonb_to_recordset(p_legacy_period_allocations) as a(payment_id uuid,amount numeric)
        where a.payment_id=v_payment.payment_id;

        select coalesce(sum((a->>'amount')::numeric),0)::numeric(14,2)
          into v_allocated
        from jsonb_array_elements(v_allocations) a
        where a->>'payment_id'=v_payment.payment_id::text
          and a->>'allocation_source'='fifo_auto';

        v_available:=v_payment.amount-v_refunded-v_payment_fixed-v_legacy_total-v_allocated;
        v_take:=least(greatest(v_available,0),greatest(v_charge_due,0),greatest(v_period_due,0));
        if v_take>0 then
          v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object(
            'payment_id',v_payment.payment_id,'charge_id',v_charge.charge_id,
            'period_id',v_charge.period_id,'amount',v_take,'allocation_source','fifo_auto'
          ));
          v_charge_due:=v_charge_due-v_take;
          v_period_due:=v_period_due-v_take;
          v_fifo_total:=v_fifo_total+v_take;
        end if;
        exit when v_charge_due<=0 or v_period_due<=0;
      end loop;
      exit when v_period_due<=0;
    end loop;

    v_period_results:=v_period_results||jsonb_build_array(jsonb_build_object(
      'period_id',v_period.period_id,'charge_total',v_period.charge_total,
      'fixed_charge_allocations',v_period_fixed,'legacy_period_allocations',v_legacy_period,
      'waived_amount',v_period_waived,'balance_after_rebuild',v_period_due
    ));
  end loop;

  for v_payment in
    select p.payment_id,p.amount,p.payment_date,p.created_at
    from jsonb_to_recordset(p_payments) as p(
      payment_id uuid,amount numeric,payment_date date,created_at timestamptz
    )
    order by p.payment_date asc nulls last,p.created_at asc nulls last,p.payment_id
  loop
    select coalesce(sum(r.amount),0)::numeric(14,2)
      into v_refunded
    from jsonb_to_recordset(p_refunds) as r(payment_id uuid,amount numeric)
    where r.payment_id=v_payment.payment_id;
    select coalesce(sum(a.amount),0)::numeric(14,2)
      into v_payment_fixed
    from jsonb_to_recordset(p_fixed_charge_allocations) as a(payment_id uuid,amount numeric)
    where a.payment_id=v_payment.payment_id;
    select coalesce(sum(a.amount),0)::numeric(14,2)
      into v_legacy_total
    from jsonb_to_recordset(p_legacy_period_allocations) as a(payment_id uuid,amount numeric)
    where a.payment_id=v_payment.payment_id;
    select coalesce(sum((a->>'amount')::numeric),0)::numeric(14,2)
      into v_allocated
    from jsonb_array_elements(v_allocations) a
    where a->>'payment_id'=v_payment.payment_id::text
      and a->>'allocation_source'='fifo_auto';
    v_payment_results:=v_payment_results||jsonb_build_array(jsonb_build_object(
      'payment_id',v_payment.payment_id,'payment_amount',v_payment.amount,
      'refund_total',v_refunded,'proposed_allocated',v_payment_fixed+v_legacy_total+v_allocated,
      'unallocated_after_rebuild',v_payment.amount-v_refunded-v_payment_fixed-v_legacy_total-v_allocated
    ));
  end loop;

  return jsonb_build_object(
    'status','simulated','proposed_allocations',v_allocations,
    'preserved_legacy_period_allocations',p_legacy_period_allocations,
    'fixed_allocations_preserved',true,'fifo_allocated_total',v_fifo_total,
    'periods',v_period_results,'payments',v_payment_results
  );
end;
$function$;

create or replace function public.vbgramg_rebuild_charge_level_fifo_for_card(p_job_card_number text)
returns jsonb
language plpgsql security definer set search_path = ''
as $function$
declare
  v_charges jsonb;
  v_payments jsonb;
  v_refunds jsonb;
  v_fixed jsonb;
  v_legacy jsonb;
  v_waivers jsonb;
  v_simulation jsonb;
  v_deleted integer := 0;
  v_inserted integer := 0;
  v_is_exempt boolean;
begin
  if nullif(pg_catalog.btrim(coalesce(p_job_card_number,'')),'') is null then
    raise exception 'A Job Card Number is required';
  end if;

  if exists (
    select 1 from public.vbgramg_charge_ledger l
    where l.job_card_number=p_job_card_number
      and l.entry_type in ('charge','other_charge','sanitationFee')
      and not coalesce(l.is_voided,false) and not coalesce(l.is_deferred,false)
      and coalesce(l.amount,0)>0 and l.period_id is null
      and not (l.entry_type='charge' and pg_catalog.btrim(coalesce(l.note,''))='Return')
  ) then
    raise exception 'FIFO rebuild blocked: an eligible charge has no Contribution Period for Job Card %',p_job_card_number;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'charge_id',l.id,'period_id',l.period_id,'period_order',p.fifo_order,
    'amount',l.amount,'charge_created_at',l.created_at
  ) order by p.fifo_order,l.created_at,l.id),'[]'::jsonb)
  into v_charges
  from public.vbgramg_charge_ledger l
  join (
    select period.id,
      row_number() over (
        order by period.contribution_month asc nulls last,
                 period.period_date asc nulls last,
                 period.created_at asc,period.id asc
      ) as fifo_order
    from public.vbgramg_periods period
  ) p on p.id=l.period_id
  where l.job_card_number=p_job_card_number
    and l.entry_type in ('charge','other_charge','sanitationFee')
    and not coalesce(l.is_voided,false) and not coalesce(l.is_deferred,false)
    and coalesce(l.amount,0)>0
    and not (l.entry_type='charge' and pg_catalog.btrim(coalesce(l.note,''))='Return');

  select coalesce(jsonb_agg(jsonb_build_object(
    'payment_id',l.id,'amount',l.amount,'payment_date',l.entry_date,'created_at',l.created_at
  ) order by l.entry_date,l.created_at,l.id),'[]'::jsonb)
  into v_payments
  from public.vbgramg_charge_ledger l
  where l.job_card_number=p_job_card_number and l.entry_type='payment'
    and not coalesce(l.is_voided,false);

  select coalesce(jsonb_agg(jsonb_build_object(
    'payment_id',r.payment_id,'amount',r.amount
  ) order by r.payment_id,r.refund_id),'[]'::jsonb)
  into v_refunds
  from public.vbgramg_payment_refund_reconciliations r
  join public.vbgramg_charge_ledger pay on pay.id=r.payment_id
  where pay.job_card_number=p_job_card_number and pay.entry_type='payment'
    and not coalesce(pay.is_voided,false);

  select coalesce(jsonb_agg(jsonb_build_object(
    'payment_id',a.payment_id,'charge_id',a.charge_id,'period_id',charge.period_id,
    'amount',a.amount,'allocation_source',a.allocation_source
  ) order by a.payment_id,a.charge_id,a.allocation_source),'[]'::jsonb)
  into v_fixed
  from public.vbgramg_charge_payment_allocations a
  join public.vbgramg_charge_ledger pay on pay.id=a.payment_id
  join public.vbgramg_charge_ledger charge on charge.id=a.charge_id
  where pay.job_card_number=p_job_card_number and charge.job_card_number=p_job_card_number
    and a.allocation_source<>'fifo_auto';

  select coalesce(jsonb_agg(jsonb_build_object(
    'payment_id',a.transaction_id,'period_id',a.period_id,'amount',a.amount
  ) order by a.transaction_id,a.period_id,a.allocation_source),'[]'::jsonb)
  into v_legacy
  from public.vbgramg_payment_allocations a
  join public.vbgramg_charge_ledger pay on pay.id=a.transaction_id
  where a.job_card_number=p_job_card_number and pay.job_card_number=p_job_card_number
    and pay.entry_type='payment' and not coalesce(pay.is_voided,false);

  select coalesce(jsonb_agg(jsonb_build_object(
    'period_id',w.period_id,'amount',w.amount
  ) order by w.period_id,w.waiver_id),'[]'::jsonb)
  into v_waivers
  from public.vbgramg_waiver_period_allocations w
  join public.vbgramg_charge_ledger waiver on waiver.id=w.waiver_id
  where w.job_card_number=p_job_card_number
    and waiver.entry_type in ('charge_waiver','forgive')
    and not coalesce(waiver.is_voided,false);

  select exists(
    select 1 from public.vbgramg_contribution_exemptions e
    where pg_catalog.btrim(e.job_card_number)=pg_catalog.btrim(p_job_card_number)
  ) into v_is_exempt;

  v_simulation:=public.vbgramg_simulate_charge_level_fifo(
    v_charges,v_payments,v_refunds,v_fixed,v_legacy,v_waivers,v_is_exempt
  );

  if v_simulation->>'status' in ('simulated','exempt') then
    -- Exempt cards must not retain stale automatic allocations. Fixed sources
    -- are never deleted by this operation.
    delete from public.vbgramg_charge_payment_allocations a
    using public.vbgramg_charge_ledger pay,public.vbgramg_charge_ledger charge
    where a.payment_id=pay.id and a.charge_id=charge.id
      and pay.job_card_number=p_job_card_number and charge.job_card_number=p_job_card_number
      and a.allocation_source='fifo_auto';
    get diagnostics v_deleted=row_count;

    if v_simulation->>'status'='simulated' then
      insert into public.vbgramg_charge_payment_allocations
        (payment_id,charge_id,amount,allocation_source,confidence,note)
      select (x->>'payment_id')::uuid,(x->>'charge_id')::uuid,
        (x->>'amount')::numeric,'fifo_auto','confirmed','Rebuilt by FTO CO calculation revision'
      from jsonb_array_elements(v_simulation->'proposed_allocations') x
      where x->>'allocation_source'='fifo_auto';
      get diagnostics v_inserted=row_count;
    end if;
  end if;

  return jsonb_build_object(
    'job_card_number',p_job_card_number,'status',v_simulation->>'status',
    'deleted_fifo_auto',v_deleted,'inserted_fifo_auto',v_inserted,
    'fifo_allocated_total',coalesce((v_simulation->>'fifo_allocated_total')::numeric,0)
  );
end;
$function$;

revoke all on function public.vbgramg_simulate_charge_level_fifo(jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,boolean)
  from public,anon,authenticated;
grant execute on function public.vbgramg_simulate_charge_level_fifo(jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,boolean)
  to service_role;
revoke all on function public.vbgramg_rebuild_charge_level_fifo_for_card(text)
  from public,anon,authenticated;
grant execute on function public.vbgramg_rebuild_charge_level_fifo_for_card(text)
  to service_role;


-- Atomically revise the CO formula for one imported FTO batch.
-- Fixed and legacy period allocations are preserved. Only charge-level fifo_auto
-- allocations are rebuilt atomically after the revised charges are written.

create or replace function public.vbgramg_apply_fto_co_revision(
  p_batch_id uuid,
  p_expected_revision_number integer,
  p_expected_period_id uuid,
  p_expected_charge_period date,
  p_expected_last_checked_at timestamptz,
  p_expected_last_deferred_recheck_at timestamptz,
  p_expected_allocation_fingerprint text,
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
  v_current_allocation_fingerprint text;
begin
  if p_batch_id is null or p_expected_revision_number is null
     or p_expected_period_id is null or p_expected_charge_period is null
     or p_expected_last_checked_at is null or p_actor_user_id is null
     or p_expected_allocation_fingerprint is null
     or p_expected_allocation_fingerprint !~ '^[a-f0-9]{32}$' then
    raise exception 'FTO batch, preview version, period, and actor are required' using errcode = '22023';
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
  if v_initial_batch.period_id is distinct from p_expected_period_id
     or v_initial_batch.ledger_charge_period is distinct from p_expected_charge_period
     or v_initial_batch.last_checked_at is distinct from p_expected_last_checked_at
     or v_initial_batch.last_deferred_recheck_at is distinct from p_expected_last_deferred_recheck_at then
    raise exception 'The FTO changed after preview. Reload its history and preview the calculation again' using errcode = '40001';
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
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtextextended('contribution-exemption:' || v_card, 0)
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
  if v_batch.period_id is distinct from p_expected_period_id
     or v_batch.ledger_charge_period is distinct from p_expected_charge_period
     or v_batch.last_checked_at is distinct from p_expected_last_checked_at
     or v_batch.last_deferred_recheck_at is distinct from p_expected_last_deferred_recheck_at then
    raise exception 'The FTO was synchronized, rechecked, or moved after preview. Preview the calculation again' using errcode = '40001';
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
  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_before->'unlinked_legacy_waivers','[]'::jsonb)) waiver
    where coalesce((waiver->>'unlinked_amount')::numeric,0)>0
       or coalesce((waiver->>'overallocated_amount')::numeric,0)>0
  ) then
    raise exception 'This FTO affects a Job Card with an unlinked or overallocated legacy waiver. Resolve the waiver before changing CO calculation' using errcode = '23514';
  end if;
  if jsonb_array_length(coalesce(v_before->'manual_charge_links','[]'::jsonb))>0 then
    raise exception 'This FTO has historical manual charge-link evidence. Review it before changing CO calculation' using errcode = '23514';
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
    join public.vbgramg_charge_ledger fto_charge on fto_charge.id = tx.ledger_entry_id
    where tx.batch_id = p_batch_id
      and tx.job_card_number = v_card
      and tx.is_current = true and tx.is_in_scope = true
      and tx.status in ('blank','processed')
      and coalesce(fto_charge.is_deferred,false) = false;

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
      and tx.is_current = true and tx.is_in_scope = true
      and a.allocation_source <> 'fifo_auto';

    if v_charge_allocated > v_new_card_total then
      raise exception 'CO revision blocked for Job Card %: charge-level allocations %.2f exceed revised CO charge %.2f',
        v_card,v_charge_allocated,v_new_card_total using errcode = '23514';
    end if;
  end loop;

  -- Rebuild only charge-level fifo_auto allocations. Manual and reviewed rows,
  -- plus legacy period-level allocations, remain untouched.
  for v_card in select unnest(v_cards) order by 1 loop
    perform public.vbgramg_rebuild_charge_level_fifo_for_card(v_card);
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
    'allocations_preserved',true,'charge_fifo_rebuilt',true,
    'old_divisor',v_initial_batch.calculation_divisor,
    'new_divisor',p_divisor,
    'old_multiplier',v_initial_batch.calculation_multiplier,
    'new_multiplier',p_multiplier
  );
end;
$function$;

revoke all on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,numeric,numeric,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,numeric,numeric,text,uuid,text)
  to service_role;

comment on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,numeric,numeric,text,uuid,text) is
  'Atomically recalculates one imported FTO batch, preserves fixed and legacy period allocations, rebuilds only charge-level fifo_auto allocations, and records before/after revision evidence.';

 then
    raise exception 'FTO batch, preview version, period, and actor are required' using errcode = '22023';
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
  if v_initial_batch.period_id is distinct from p_expected_period_id
     or v_initial_batch.ledger_charge_period is distinct from p_expected_charge_period
     or v_initial_batch.last_checked_at is distinct from p_expected_last_checked_at
     or v_initial_batch.last_deferred_recheck_at is distinct from p_expected_last_deferred_recheck_at then
    raise exception 'The FTO changed after preview. Reload its history and preview the calculation again' using errcode = '40001';
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
  if v_batch.period_id is distinct from p_expected_period_id
     or v_batch.ledger_charge_period is distinct from p_expected_charge_period
     or v_batch.last_checked_at is distinct from p_expected_last_checked_at
     or v_batch.last_deferred_recheck_at is distinct from p_expected_last_deferred_recheck_at then
    raise exception 'The FTO was synchronized, rechecked, or moved after preview. Preview the calculation again' using errcode = '40001';
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

  -- Lock all financial rows that participate in the preview fingerprint before
  -- comparing it, so a concurrent payment/allocation edit cannot slip into Apply.
  perform l.id
  from public.vbgramg_charge_ledger l
  where pg_catalog.upper(pg_catalog.btrim(l.job_card_number))=any(v_cards)
  order by l.job_card_number,l.id
  for update;
  perform a.id
  from public.vbgramg_charge_payment_allocations a
  join public.vbgramg_charge_ledger pay on pay.id=a.payment_id
  join public.vbgramg_charge_ledger charge on charge.id=a.charge_id
  where pg_catalog.upper(pg_catalog.btrim(pay.job_card_number))=any(v_cards)
     or pg_catalog.upper(pg_catalog.btrim(charge.job_card_number))=any(v_cards)
  order by a.payment_id,a.charge_id,a.allocation_source,a.id
  for update of a;
  perform a.id
  from public.vbgramg_payment_allocations a
  where pg_catalog.upper(pg_catalog.btrim(a.job_card_number))=any(v_cards)
  order by a.transaction_id,a.period_id,a.allocation_source,a.id
  for update;
  perform r.payment_id
  from public.vbgramg_payment_refund_reconciliations r
  join public.vbgramg_charge_ledger pay on pay.id=r.payment_id
  where pg_catalog.upper(pg_catalog.btrim(pay.job_card_number))=any(v_cards)
  order by r.payment_id,r.refund_id
  for update of r;
  perform w.id
  from public.vbgramg_waiver_period_allocations w
  where pg_catalog.upper(pg_catalog.btrim(w.job_card_number))=any(v_cards)
  order by w.waiver_id,w.period_id,w.id
  for update;

  v_current_allocation_fingerprint:=public.vbgramg_fto_co_revision_fingerprint(p_batch_id);
  if v_current_allocation_fingerprint is distinct from p_expected_allocation_fingerprint then
    raise exception 'Contribution payments or allocations changed after preview. Preview the CO calculation again before applying' using errcode = '40001';
  end if;

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
    join public.vbgramg_charge_ledger fto_charge on fto_charge.id = tx.ledger_entry_id
    where tx.batch_id = p_batch_id
      and tx.job_card_number = v_card
      and tx.is_current = true and tx.is_in_scope = true
      and tx.status in ('blank','processed')
      and coalesce(fto_charge.is_deferred,false) = false;

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
      and tx.is_current = true and tx.is_in_scope = true
      and a.allocation_source <> 'fifo_auto';

    if v_charge_allocated > v_new_card_total then
      raise exception 'CO revision blocked for Job Card %: charge-level allocations %.2f exceed revised CO charge %.2f',
        v_card,v_charge_allocated,v_new_card_total using errcode = '23514';
    end if;
  end loop;

  -- Rebuild only charge-level fifo_auto allocations. Manual and reviewed rows,
  -- plus legacy period-level allocations, remain untouched.
  for v_card in select unnest(v_cards) order by 1 loop
    perform public.vbgramg_rebuild_charge_level_fifo_for_card(v_card);
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
    'allocations_preserved',true,'charge_fifo_rebuilt',true,
    'old_divisor',v_initial_batch.calculation_divisor,
    'new_divisor',p_divisor,
    'old_multiplier',v_initial_batch.calculation_multiplier,
    'new_multiplier',p_multiplier
  );
end;
$function$;

revoke all on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,text,numeric,numeric,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,text,numeric,numeric,text,uuid,text)
  to service_role;

comment on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,text,numeric,numeric,text,uuid,text) is
  'Atomically recalculates one imported FTO batch, verifies the preview allocation fingerprint, preserves fixed and legacy period allocations, rebuilds only charge-level fifo_auto allocations, and records before/after revision evidence.';

 then
    raise exception 'FTO batch, preview version, period, and actor are required' using errcode = '22023';
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
  if v_initial_batch.period_id is distinct from p_expected_period_id
     or v_initial_batch.ledger_charge_period is distinct from p_expected_charge_period
     or v_initial_batch.last_checked_at is distinct from p_expected_last_checked_at
     or v_initial_batch.last_deferred_recheck_at is distinct from p_expected_last_deferred_recheck_at then
    raise exception 'The FTO changed after preview. Reload its history and preview the calculation again' using errcode = '40001';
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
  if v_batch.period_id is distinct from p_expected_period_id
     or v_batch.ledger_charge_period is distinct from p_expected_charge_period
     or v_batch.last_checked_at is distinct from p_expected_last_checked_at
     or v_batch.last_deferred_recheck_at is distinct from p_expected_last_deferred_recheck_at then
    raise exception 'The FTO was synchronized, rechecked, or moved after preview. Preview the calculation again' using errcode = '40001';
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
    join public.vbgramg_charge_ledger fto_charge on fto_charge.id = tx.ledger_entry_id
    where tx.batch_id = p_batch_id
      and tx.job_card_number = v_card
      and tx.is_current = true and tx.is_in_scope = true
      and tx.status in ('blank','processed')
      and coalesce(fto_charge.is_deferred,false) = false;

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
      and tx.is_current = true and tx.is_in_scope = true
      and a.allocation_source <> 'fifo_auto';

    if v_charge_allocated > v_new_card_total then
      raise exception 'CO revision blocked for Job Card %: charge-level allocations %.2f exceed revised CO charge %.2f',
        v_card,v_charge_allocated,v_new_card_total using errcode = '23514';
    end if;
  end loop;

  -- Rebuild only charge-level fifo_auto allocations. Manual and reviewed rows,
  -- plus legacy period-level allocations, remain untouched.
  for v_card in select unnest(v_cards) order by 1 loop
    perform public.vbgramg_rebuild_charge_level_fifo_for_card(v_card);
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
    'allocations_preserved',true,'charge_fifo_rebuilt',true,
    'old_divisor',v_initial_batch.calculation_divisor,
    'new_divisor',p_divisor,
    'old_multiplier',v_initial_batch.calculation_multiplier,
    'new_multiplier',p_multiplier
  );
end;
$function$;

revoke all on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,numeric,numeric,text,uuid,text)
  from public, anon, authenticated;
grant execute on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,numeric,numeric,text,uuid,text)
  to service_role;

comment on function public.vbgramg_apply_fto_co_revision(uuid,integer,uuid,date,timestamptz,timestamptz,numeric,numeric,text,uuid,text) is
  'Atomically recalculates one imported FTO batch, preserves fixed and legacy period allocations, rebuilds only charge-level fifo_auto allocations, and records before/after revision evidence.';

