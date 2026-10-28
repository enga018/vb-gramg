-- Harden atomic payment allocation replacement.
-- Reject malformed/duplicate rows before deleting the existing allocations.
create or replace function public.vbgramg_replace_payment_allocations(
  p_transaction_id uuid,
  p_allocations jsonb,
  p_allocation_source text default 'manual',
  p_user_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  tx public.vbgramg_charge_ledger%rowtype;
  item jsonb;
  period_value uuid;
  amount_value numeric(12,2);
  confidence_value text;
  total numeric(12,2) := 0;
  inserted_count integer := 0;
  seen_periods uuid[] := array[]::uuid[];
begin
  select * into tx
  from public.vbgramg_charge_ledger
  where id = p_transaction_id
  for update;

  if not found or tx.entry_type <> 'payment' then
    raise exception 'Valid payment transaction required';
  end if;
  if p_allocation_source not in ('fifo_auto','manual','historical_evidence','historical_fifo_reviewed') then
    raise exception 'Invalid allocation source';
  end if;
  if jsonb_typeof(p_allocations) <> 'array' then
    raise exception 'Allocations must be an array';
  end if;
  if jsonb_array_length(p_allocations) > 100 then
    raise exception 'Too many allocation rows';
  end if;

  for item in select value from jsonb_array_elements(p_allocations) loop
    begin
      period_value := nullif(item->>'period_id','')::uuid;
      amount_value := (item->>'amount')::numeric(12,2);
    exception when others then
      raise exception 'Each allocation needs a valid period UUID and amount';
    end;

    if period_value is null or amount_value is null or amount_value <= 0 then
      raise exception 'Each allocation needs a valid period and positive amount';
    end if;
    if period_value = any(seen_periods) then
      raise exception 'Duplicate period rows are not allowed; combine amounts for the same period';
    end if;
    seen_periods := array_append(seen_periods, period_value);

    confidence_value := coalesce(nullif(item->>'confidence',''),'confirmed');
    if confidence_value not in ('confirmed','probable','review_required') then
      raise exception 'Invalid allocation confidence';
    end if;

    if not exists (
      select 1
      from public.vbgramg_charge_ledger c
      where c.job_card_number = tx.job_card_number
        and c.period_id = period_value
        and c.entry_type in ('charge','other_charge')
        and not coalesce(c.is_deferred,false)
    ) then
      raise exception 'Selected period has no eligible charge for this job card';
    end if;
    total := total + amount_value;
  end loop;

  if total > tx.amount then
    raise exception 'Allocations exceed payment amount';
  end if;

  delete from public.vbgramg_payment_allocations
  where transaction_id = p_transaction_id;

  for item in select value from jsonb_array_elements(p_allocations) loop
    insert into public.vbgramg_payment_allocations(
      transaction_id, period_id, job_card_number, amount,
      allocation_source, confidence, note, created_by
    )
    values (
      p_transaction_id,
      (item->>'period_id')::uuid,
      tx.job_card_number,
      (item->>'amount')::numeric(12,2),
      p_allocation_source,
      coalesce(nullif(item->>'confidence',''),'confirmed'),
      nullif(item->>'note',''),
      p_user_id
    );
    inserted_count := inserted_count + 1;
  end loop;

  return jsonb_build_object(
    'transaction_id', p_transaction_id,
    'allocated_amount', total,
    'unallocated_amount', tx.amount-total,
    'allocation_count', inserted_count
  );
end;
$function$;

revoke all on function public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid) from public, anon, authenticated;
grant execute on function public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid) to service_role;
