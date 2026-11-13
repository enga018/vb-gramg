-- Extend the read-only FTO revision snapshot with durable manual-link evidence
-- and current charge-level allocations. No financial records are modified.
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
            order by p.contribution_month asc nulls last,
                     p.period_date asc nulls last,
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
    -- The balance breakdown applies charge_waiver/forgive globally FIFO.
    -- Any amount not explicitly linked to a period cannot be simulated safely.
    -- Return its exact unlinked remainder so preview can fail closed.
    'manual_charge_links', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'ledger_entry_id', a.ledger_entry_id,
          'job_card_number', a.job_card_number,
          'before_data', a.before_data,
          'after_data', a.after_data,
          'created_at', a.created_at
        )
        order by a.created_at, a.id
      )
      from public.vbgramg_ledger_audit a
      where a.job_card_number = any(v_cards)
        and a.action = 'manual_charge_linked_to_fto'
    ), '[]'::jsonb),
    'charge_payment_allocations', coalesce((
      select jsonb_agg(
        to_jsonb(a) || jsonb_build_object(
          'payment_is_voided', coalesce(payment.is_voided, false),
          'payment_entry_type', payment.entry_type,
          'charge_is_voided', coalesce(charge.is_voided, false),
          'charge_is_deferred', coalesce(charge.is_deferred, false),
          'charge_period_id', charge.period_id
        )
        order by a.job_card_number, charge.period_id, a.payment_id, a.charge_id
      )
      from public.vbgramg_charge_payment_allocations a
      join public.vbgramg_charge_ledger payment on payment.id = a.payment_id
      join public.vbgramg_charge_ledger charge on charge.id = a.charge_id
      where a.job_card_number = any(v_cards)
    ), '[]'::jsonb),
    'unlinked_legacy_waivers', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'waiver_id', waiver.id,
          'job_card_number', waiver.job_card_number,
          'entry_type', waiver.entry_type,
          'amount', waiver.amount,
          'linked_amount', coalesce(linked.total_linked, 0),
          'unlinked_amount', greatest(waiver.amount - coalesce(linked.total_linked, 0), 0),
          'overallocated_amount', greatest(coalesce(linked.total_linked, 0) - waiver.amount, 0)
        )
        order by waiver.job_card_number, waiver.created_at, waiver.id
      )
      from public.vbgramg_charge_ledger waiver
      left join lateral (
        select sum(w.amount)::numeric(14,2) as total_linked
        from public.vbgramg_waiver_period_allocations w
        where w.waiver_id = waiver.id
          and w.job_card_number = waiver.job_card_number
      ) linked on true
      where waiver.job_card_number = any(v_cards)
        and waiver.entry_type in ('charge_waiver', 'forgive')
        and not coalesce(waiver.is_voided, false)
        and (
          greatest(waiver.amount - coalesce(linked.total_linked, 0), 0) > 0
          or greatest(coalesce(linked.total_linked, 0) - waiver.amount, 0) > 0
        )
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
