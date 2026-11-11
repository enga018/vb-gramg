-- Pure simulation of the production automatic allocator.
-- This function performs no writes and accepts a complete, caller-built snapshot.
-- Period order and payment order intentionally mirror
-- vbgramg_auto_allocate_unallocated_payments(text).
create or replace function public.vbgramg_simulate_fifo_allocator(
  p_periods jsonb,
  p_payments jsonb,
  p_allocations jsonb,
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
  v_period_due numeric(14,2);
  v_payment_available numeric(14,2);
  v_payment_allocated numeric(14,2);
  v_payment_refunded numeric(14,2);
  v_existing_period_allocated numeric(14,2);
  v_existing_period_waived numeric(14,2);
  v_take numeric(14,2);
  v_allocations jsonb := '[]'::jsonb;
  v_periods jsonb := '[]'::jsonb;
  v_total numeric(14,2) := 0;
begin
  if jsonb_typeof(p_periods) <> 'array'
     or jsonb_typeof(p_payments) <> 'array'
     or jsonb_typeof(p_allocations) <> 'array'
     or jsonb_typeof(p_refunds) <> 'array'
     or jsonb_array_length(p_periods) > 10000
     or jsonb_array_length(p_payments) > 10000
     or jsonb_array_length(p_allocations) > 50000
     or jsonb_array_length(p_refunds) > 50000 then
    raise exception 'FIFO simulation inputs must be bounded JSON arrays';
  end if;

  if p_is_exempt then
    return jsonb_build_object(
      'status','exempt','proposed_allocations','[]'::jsonb,
      'periods','[]'::jsonb,'allocated_total',0
    );
  end if;

  for v_period in
    select x.period_id, x.period_order, x.eligible_charges, x.linked_waivers
    from jsonb_to_recordset(p_periods) as x(
      period_id uuid, period_order integer,
      eligible_charges numeric, linked_waivers numeric
    )
    order by x.period_order asc, x.period_id asc
  loop
    if v_period.period_id is null or v_period.eligible_charges is null
       or v_period.eligible_charges < 0
       or coalesce(v_period.linked_waivers,0) < 0 then
      raise exception 'Invalid period row in FIFO simulation';
    end if;

    select coalesce(sum(x.amount),0)::numeric(14,2)
      into v_existing_period_allocated
    from jsonb_to_recordset(p_allocations) as x(
      payment_id uuid, period_id uuid, amount numeric
    )
    where x.period_id = v_period.period_id;

    v_existing_period_waived := coalesce(v_period.linked_waivers,0);
    v_period_due := greatest(
      v_period.eligible_charges - v_existing_period_allocated - v_existing_period_waived,
      0
    );

    for v_payment in
      select x.payment_id, x.amount, x.payment_date, x.created_at
      from jsonb_to_recordset(p_payments) as x(
        payment_id uuid, amount numeric, payment_date date, created_at timestamptz
      )
      order by x.payment_date asc nulls last, x.created_at asc nulls last, x.payment_id asc
    loop
      if v_payment.payment_id is null or v_payment.amount is null or v_payment.amount < 0 then
        raise exception 'Invalid payment row in FIFO simulation';
      end if;

      select coalesce(sum(x.amount),0)::numeric(14,2)
        into v_payment_allocated
      from jsonb_to_recordset(p_allocations) as x(
        payment_id uuid, period_id uuid, amount numeric
      )
      where x.payment_id = v_payment.payment_id;

      select coalesce(sum(x.amount),0)::numeric(14,2)
        into v_payment_refunded
      from jsonb_to_recordset(p_refunds) as x(payment_id uuid, amount numeric)
      where x.payment_id = v_payment.payment_id;

      select coalesce(sum((x->>'amount')::numeric),0)::numeric(14,2)
        into v_payment_allocated
      from jsonb_array_elements(v_allocations) x
      where x->>'payment_id' = v_payment.payment_id::text;

      v_payment_available := greatest(
        v_payment.amount - v_payment_allocated
        - (select coalesce(sum(x.amount),0)
           from jsonb_to_recordset(p_refunds) as x(payment_id uuid, amount numeric)
           where x.payment_id = v_payment.payment_id),
        0
      );
      v_take := least(v_payment_available, v_period_due);

      if v_take > 0 then
        v_allocations := v_allocations || jsonb_build_array(jsonb_build_object(
          'payment_id',v_payment.payment_id,
          'period_id',v_period.period_id,
          'amount',v_take
        ));
        v_period_due := v_period_due - v_take;
        v_total := v_total + v_take;
      end if;

      exit when v_period_due <= 0;
    end loop;

    v_periods := v_periods || jsonb_build_array(jsonb_build_object(
      'period_id',v_period.period_id,
      'eligible_charges',v_period.eligible_charges,
      'existing_allocations',v_existing_period_allocated,
      'linked_waivers',v_existing_period_waived,
      'due_before_simulation',greatest(
        v_period.eligible_charges-v_existing_period_allocated-v_existing_period_waived,0
      ),
      'due_after_simulation',v_period_due
    ));
  end loop;

  return jsonb_build_object(
    'status','simulated',
    'proposed_allocations',v_allocations,
    'periods',v_periods,
    'allocated_total',v_total
  );
end;
$function$;

revoke all on function public.vbgramg_simulate_fifo_allocator(jsonb,jsonb,jsonb,jsonb,boolean)
  from public, anon, authenticated;
grant execute on function public.vbgramg_simulate_fifo_allocator(jsonb,jsonb,jsonb,jsonb,boolean)
  to service_role;
