-- Full-rebuild FIFO planner for FTO revision previews.
-- Unlike vbgramg_simulate_fifo_allocator, this function deliberately ignores
-- existing payment allocations: callers provide revised period balances,
-- payments and refunds, while preserving waiver allocations as period inputs.
-- Pure JSON calculation only; no ledger or allocation rows are written.

create or replace function public.vbgramg_simulate_fifo_rebuild(
  p_periods jsonb,
  p_payments jsonb,
  p_refunds jsonb,
  p_is_exempt boolean default false
)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $function$
declare
  v_period record;
  v_payment record;
  v_due numeric(14,2);
  v_available numeric(14,2);
  v_refunded numeric(14,2);
  v_take numeric(14,2);
  v_allocations jsonb := '[]'::jsonb;
  v_period_results jsonb := '[]'::jsonb;
  v_payment_results jsonb := '[]'::jsonb;
  v_total numeric(14,2) := 0;
begin
  if p_periods is null or p_payments is null or p_refunds is null
     or jsonb_typeof(p_periods) <> 'array'
     or jsonb_typeof(p_payments) <> 'array'
     or jsonb_typeof(p_refunds) <> 'array'
     or jsonb_array_length(p_periods) > 10000
     or jsonb_array_length(p_payments) > 10000
     or jsonb_array_length(p_refunds) > 50000 then
    raise exception 'FIFO rebuild inputs must be bounded JSON arrays';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_periods) as x(
      period_id uuid, period_order integer,
      eligible_charges numeric, linked_waivers numeric
    )
    where x.period_id is null or x.period_order is null
       or x.eligible_charges is null or x.eligible_charges < 0
       or coalesce(x.linked_waivers,0) < 0
       or coalesce(x.linked_waivers,0) > x.eligible_charges
  ) then
    raise exception 'Invalid period or preserved waiver balance in FIFO rebuild';
  end if;

  if exists (
    select 1 from (
      select x.period_id
      from jsonb_to_recordset(p_periods) as x(period_id uuid)
      group by x.period_id having count(*) > 1
    ) duplicates
  ) then
    raise exception 'Duplicate period in FIFO rebuild';
  end if;

  if exists (
    select 1 from (
      select x.period_order
      from jsonb_to_recordset(p_periods) as x(period_order integer)
      group by x.period_order having count(*) > 1
    ) duplicates
  ) then
    raise exception 'Duplicate period order in FIFO rebuild';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_payments) as x(
      payment_id uuid, amount numeric, payment_date date, created_at timestamptz
    )
    where x.payment_id is null or x.amount is null or x.amount < 0
  ) then
    raise exception 'Invalid payment in FIFO rebuild';
  end if;

  if exists (
    select 1 from (
      select x.payment_id
      from jsonb_to_recordset(p_payments) as x(payment_id uuid)
      group by x.payment_id having count(*) > 1
    ) duplicates
  ) then
    raise exception 'Duplicate payment in FIFO rebuild';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_refunds) as x(payment_id uuid, amount numeric)
    where x.payment_id is null or x.amount is null or x.amount < 0
  ) then
    raise exception 'Invalid refund in FIFO rebuild';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_refunds) as r(payment_id uuid, amount numeric)
    left join jsonb_to_recordset(p_payments) as p(payment_id uuid, amount numeric)
      on p.payment_id = r.payment_id
    where p.payment_id is null
  ) then
    raise exception 'Refund refers to a payment outside the revision scope';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_payments) as p(payment_id uuid, amount numeric)
    left join lateral (
      select coalesce(sum(r.amount),0) as total
      from jsonb_to_recordset(p_refunds) as r(payment_id uuid, amount numeric)
      where r.payment_id = p.payment_id
    ) refunds on true
    where refunds.total > p.amount
  ) then
    raise exception 'Refund total exceeds payment amount';
  end if;

  if p_is_exempt then
    return jsonb_build_object(
      'status','exempt',
      'proposed_allocations','[]'::jsonb,
      'periods','[]'::jsonb,
      'payments','[]'::jsonb,
      'allocated_total',0
    );
  end if;

  -- Payments are exhausted against periods in the production FIFO order.
  for v_period in
    select x.period_id, x.period_order, x.eligible_charges,
           coalesce(x.linked_waivers,0)::numeric(14,2) as linked_waivers
    from jsonb_to_recordset(p_periods) as x(
      period_id uuid, period_order integer,
      eligible_charges numeric, linked_waivers numeric
    )
    order by x.period_order, x.period_id
  loop
    v_due := v_period.eligible_charges - v_period.linked_waivers;

    for v_payment in
      select x.payment_id, x.amount, x.payment_date, x.created_at
      from jsonb_to_recordset(p_payments) as x(
        payment_id uuid, amount numeric, payment_date date, created_at timestamptz
      )
      order by x.payment_date asc nulls last,
               x.created_at asc nulls last, x.payment_id asc
    loop
      select coalesce(sum(r.amount),0)::numeric(14,2)
        into v_refunded
      from jsonb_to_recordset(p_refunds) as r(payment_id uuid, amount numeric)
      where r.payment_id = v_payment.payment_id;

      select coalesce(sum((a->>'amount')::numeric),0)::numeric(14,2)
        into v_available
      from jsonb_array_elements(v_allocations) a
      where a->>'payment_id' = v_payment.payment_id::text;

      v_available := v_payment.amount - v_refunded - v_available;
      v_take := least(greatest(v_available,0),v_due);

      if v_take > 0 then
        v_allocations := v_allocations || jsonb_build_array(jsonb_build_object(
          'payment_id',v_payment.payment_id,
          'period_id',v_period.period_id,
          'amount',v_take
        ));
        v_due := v_due - v_take;
        v_total := v_total + v_take;
      end if;

      exit when v_due = 0;
    end loop;

    v_period_results := v_period_results || jsonb_build_array(jsonb_build_object(
      'period_id',v_period.period_id,
      'eligible_charges',v_period.eligible_charges,
      'preserved_waivers',v_period.linked_waivers,
      'due_after_rebuild',v_due
    ));
  end loop;

  for v_payment in
    select x.payment_id, x.amount, x.payment_date, x.created_at
    from jsonb_to_recordset(p_payments) as x(
      payment_id uuid, amount numeric, payment_date date, created_at timestamptz
    )
    order by x.payment_date asc nulls last,
             x.created_at asc nulls last, x.payment_id asc
  loop
    select coalesce(sum(r.amount),0)::numeric(14,2)
      into v_refunded
    from jsonb_to_recordset(p_refunds) as r(payment_id uuid, amount numeric)
    where r.payment_id = v_payment.payment_id;

    select coalesce(sum((a->>'amount')::numeric),0)::numeric(14,2)
      into v_available
    from jsonb_array_elements(v_allocations) a
    where a->>'payment_id' = v_payment.payment_id::text;

    v_payment_results := v_payment_results || jsonb_build_array(jsonb_build_object(
      'payment_id',v_payment.payment_id,
      'payment_amount',v_payment.amount,
      'refund_total',v_refunded,
      'proposed_allocated',v_available,
      'unallocated_after_rebuild',v_payment.amount-v_refunded-v_available
    ));
  end loop;

  return jsonb_build_object(
    'status','simulated',
    'proposed_allocations',v_allocations,
    'periods',v_period_results,
    'payments',v_payment_results,
    'allocated_total',v_total
  );
end;
$function$;

revoke all on function public.vbgramg_simulate_fifo_rebuild(jsonb,jsonb,jsonb,boolean)
  from public, anon, authenticated;
grant execute on function public.vbgramg_simulate_fifo_rebuild(jsonb,jsonb,jsonb,boolean)
  to service_role;

comment on function public.vbgramg_simulate_fifo_rebuild(jsonb,jsonb,jsonb,boolean) is
  'Pure full-rebuild FIFO simulation for FTO revision previews. Ignores old payment allocations, preserves supplied waiver balances, and deducts all refunds from payment availability.';
