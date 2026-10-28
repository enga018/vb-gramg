-- Atomic replacement RPC used by the protected contribution Edge Function.
create or replace function public.vbgramg_replace_payment_allocations(
  p_transaction_id uuid,
  p_allocations jsonb,
  p_allocation_source text default 'manual',
  p_user_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public
as $$
declare tx public.vbgramg_charge_ledger%rowtype; item jsonb; total numeric(12,2) := 0; inserted_count integer := 0;
begin
  select * into tx from public.vbgramg_charge_ledger where id = p_transaction_id for update;
  if not found or tx.entry_type <> 'payment' then raise exception 'Valid payment transaction required'; end if;
  if p_allocation_source not in ('fifo_auto','manual','historical_evidence','historical_fifo_reviewed') then raise exception 'Invalid allocation source'; end if;
  if jsonb_typeof(p_allocations) <> 'array' then raise exception 'Allocations must be an array'; end if;
  for item in select value from jsonb_array_elements(p_allocations) loop
    if nullif(item->>'period_id','') is null or coalesce((item->>'amount')::numeric,0) <= 0 then raise exception 'Each allocation needs a period and positive amount'; end if;
    if not exists (select 1 from public.vbgramg_charge_ledger c where c.job_card_number=tx.job_card_number and c.period_id=(item->>'period_id')::uuid and c.entry_type in ('charge','other_charge') and not c.is_deferred) then raise exception 'Selected period has no eligible charge for this job card'; end if;
    total := total + (item->>'amount')::numeric;
  end loop;
  if total > tx.amount then raise exception 'Allocations exceed payment amount'; end if;
  delete from public.vbgramg_payment_allocations where transaction_id=p_transaction_id;
  for item in select value from jsonb_array_elements(p_allocations) loop
    insert into public.vbgramg_payment_allocations(transaction_id,period_id,job_card_number,amount,allocation_source,confidence,note,created_by)
    values(p_transaction_id,(item->>'period_id')::uuid,tx.job_card_number,(item->>'amount')::numeric,p_allocation_source,coalesce(nullif(item->>'confidence',''),'confirmed'),nullif(item->>'note',''),p_user_id);
    inserted_count := inserted_count+1;
  end loop;
  return jsonb_build_object('transaction_id',p_transaction_id,'allocated_amount',total,'unallocated_amount',tx.amount-total,'allocation_count',inserted_count);
end; $$;
revoke all on function public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid) from public, anon, authenticated;
grant execute on function public.vbgramg_replace_payment_allocations(uuid,jsonb,text,uuid) to service_role;
