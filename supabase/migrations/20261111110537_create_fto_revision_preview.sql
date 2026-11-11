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
  v_conflicts jsonb := '[]'::jsonb;
begin
  if p_periods is null or p_payments is null or p_allocations is null or p_refunds is null
     or jsonb_typeof(p_periods) <> 'array'
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
    if v_existing_period_allocated >
       greatest(v_period.eligible_charges - v_existing_period_waived, 0) then
      v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
        'period_id', v_period.period_id,
        'eligible_charges', v_period.eligible_charges,
        'existing_allocations', v_existing_period_allocated,
        'linked_waivers', v_existing_period_waived,
        'excess_allocated', v_existing_period_allocated
          - greatest(v_period.eligible_charges - v_existing_period_waived, 0)
      ));
    end if;

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

      select v_payment_allocated + coalesce(sum((x->>'amount')::numeric),0)::numeric(14,2)
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

  if jsonb_array_length(v_conflicts) > 0 then
    return jsonb_build_object(
      'status','allocation_conflict',
      'conflicts',v_conflicts,
      'proposed_allocations','[]'::jsonb,
      'periods',v_periods,
      'allocated_total',0
    );
  end if;

  return jsonb_build_object(
    'status','simulated',
    'conflicts','[]'::jsonb,
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


-- Read-only snapshot of every ledger component needed to preview a revision.
-- The caller still has to build the proposed batch replacement and run the
-- FIFO simulator; this function never changes financial records.
create or replace function public.vbgramg_get_fto_revision_snapshot(
  p_batch_id uuid,
  p_target_period_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
  v_batch jsonb;
  v_cards text[];
  v_result jsonb;
begin
  if p_batch_id is null then
    raise exception 'FTO batch ID is required';
  end if;

  select to_jsonb(b)
    into v_batch
  from public.vbgramg_fto_batches b
  where b.id = p_batch_id;

  if v_batch is null then
    raise exception 'FTO batch not found';
  end if;

  -- Include current and superseded in-scope transactions. Out-of-scope
  -- village rows must never expand the contribution revision scope.
  select coalesce(array_agg(distinct t.job_card_number order by t.job_card_number)
                    filter (where t.job_card_number is not null),
                  array[]::text[])
    into v_cards
  from public.vbgramg_fto_transactions t
  where t.batch_id = p_batch_id
    and coalesce(t.is_in_scope, true);

  if p_target_period_id is not null and not exists (
    select 1 from public.vbgramg_periods p where p.id = p_target_period_id
  ) then
    raise exception 'Target contribution period not found';
  end if;

  select jsonb_build_object(
    'batch', v_batch,
    'transactions', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.reference_no, t.id)
      from public.vbgramg_fto_transactions t
      where t.batch_id = p_batch_id
    ), '[]'::jsonb),
    'job_cards', to_jsonb(v_cards),
    'ledger_entries', coalesce((
      select jsonb_agg(to_jsonb(c) order by c.job_card_number, c.entry_date nulls last, c.created_at, c.id)
      from public.vbgramg_charge_ledger c
      where c.job_card_number = any(v_cards)
    ), '[]'::jsonb),
    'periods', coalesce((
      select jsonb_agg(
        to_jsonb(p) || jsonb_build_object('fifo_order', ordered.fifo_order)
        order by ordered.fifo_order
      )
      from (
        select distinct p.id, p.contribution_month, p.period_date, p.created_at,
          row_number() over (
            order by coalesce(p.contribution_month, p.period_date) asc nulls last,
                     p.created_at asc, p.id asc
          ) as fifo_order
        from public.vbgramg_periods p
        where p.id = p_target_period_id
           or p.id in (
          select c.period_id
          from public.vbgramg_charge_ledger c
          where c.job_card_number = any(v_cards) and c.period_id is not null
          union
          select a.period_id
          from public.vbgramg_payment_allocations a
          where a.job_card_number = any(v_cards)
          union
          select w.period_id
          from public.vbgramg_waiver_period_allocations w
          where w.job_card_number = any(v_cards)
        )
      ) ordered
      join public.vbgramg_periods p on p.id = ordered.id
    ), '[]'::jsonb),
    'payment_allocations', coalesce((
      select jsonb_agg(
        to_jsonb(a) || jsonb_build_object(
          'payment_is_voided', coalesce(payment.is_voided, false),
          'payment_entry_type', payment.entry_type
        )
        order by a.job_card_number, a.period_id, a.transaction_id
      )
      from public.vbgramg_payment_allocations a
      join public.vbgramg_charge_ledger payment on payment.id = a.transaction_id
      where a.job_card_number = any(v_cards)
    ), '[]'::jsonb),
    'payment_refunds', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.payment_id, r.created_at, r.id)
      from public.vbgramg_payment_refund_reconciliations r
      where r.job_card_number = any(v_cards)
    ), '[]'::jsonb),
    'waiver_allocations', coalesce((
      select jsonb_agg(
        to_jsonb(w) || jsonb_build_object(
          'waiver_is_voided', coalesce(waiver.is_voided, false),
          'waiver_entry_type', waiver.entry_type
        )
        order by w.job_card_number, w.period_id, w.waiver_id
      )
      from public.vbgramg_waiver_period_allocations w
      join public.vbgramg_charge_ledger waiver on waiver.id = w.waiver_id
      where w.job_card_number = any(v_cards)
    ), '[]'::jsonb),
    'active_exemptions', coalesce((
      select jsonb_agg(to_jsonb(e) order by e.job_card_number)
      from public.vbgramg_contribution_exemptions e
      where e.job_card_number = any(v_cards)
    ), '[]'::jsonb),
    'exemption_history', coalesce((
      select jsonb_agg(to_jsonb(h) order by h.job_card_number, h.started_at, h.id)
      from public.vbgramg_contribution_exemption_history h
      where h.job_card_number = any(v_cards)
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;

revoke all on function public.vbgramg_get_fto_revision_snapshot(uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.vbgramg_get_fto_revision_snapshot(uuid,uuid)
  to service_role;

comment on function public.vbgramg_get_fto_revision_snapshot(uuid,uuid) is
  'Read-only snapshot for FTO revision preview; returns the batch, current and historical FTO transactions, all affected job-card ledger entries, periods, allocations, refunds, waivers, and exemption history.';
