-- Read-only charge-level FIFO planner used by CO revision preview and Apply.
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

revoke all on function public.vbgramg_simulate_charge_level_fifo(jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,boolean)
  from public,anon,authenticated;
grant execute on function public.vbgramg_simulate_charge_level_fifo(jsonb,jsonb,jsonb,jsonb,jsonb,jsonb,boolean)
  to service_role;
