\set ON_ERROR_STOP on

\ir ../supabase/migrations/20261113180000_add_fto_revision_fifo_rebuild.sql

do $$
declare
  v_result jsonb;
  v_allocations jsonb;
begin
  -- Existing allocations are intentionally not an input. The planner starts
  -- again from payment amount less refunds and walks periods oldest first.
  v_result := public.vbgramg_simulate_fifo_rebuild(
    '[
      {"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":50,"linked_waivers":5},
      {"period_id":"00000000-0000-0000-0000-000000000002","period_order":2,"eligible_charges":40,"linked_waivers":0}
    ]'::jsonb,
    '[
      {"payment_id":"10000000-0000-0000-0000-000000000001","amount":50,"payment_date":"2026-01-01","created_at":"2026-01-01T09:00:00Z"},
      {"payment_id":"10000000-0000-0000-0000-000000000002","amount":100,"payment_date":"2026-01-02","created_at":"2026-01-02T09:00:00Z"}
    ]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000002","amount":10}]'::jsonb,
    false
  );

  v_allocations := v_result->'proposed_allocations';
  if v_result->>'status' <> 'simulated'
     or (v_result->>'allocated_total')::numeric <> 85
     or jsonb_array_length(v_allocations) <> 3 then
    raise exception 'Unexpected full FIFO rebuild result: %',v_result;
  end if;

  if (v_allocations->0->>'payment_id') <> '10000000-0000-0000-0000-000000000001'
     or (v_allocations->0->>'period_id') <> '00000000-0000-0000-0000-000000000001'
     or (v_allocations->0->>'amount')::numeric <> 45 then
    raise exception 'First payment did not fill oldest period after waiver: %',v_allocations;
  end if;

  if (v_allocations->1->>'payment_id') <> '10000000-0000-0000-0000-000000000001'
     or (v_allocations->1->>'period_id') <> '00000000-0000-0000-0000-000000000002'
     or (v_allocations->1->>'amount')::numeric <> 5 then
    raise exception 'Remaining first-payment balance was not carried to next period: %',v_allocations;
  end if;

  if (v_allocations->2->>'payment_id') <> '10000000-0000-0000-0000-000000000002'
     or (v_allocations->2->>'period_id') <> '00000000-0000-0000-0000-000000000002'
     or (v_allocations->2->>'amount')::numeric <> 35 then
    raise exception 'Second payment did not complete next period: %',v_allocations;
  end if;
end
$$;

-- A waiver greater than the revised eligible charges must fail closed.
do $$
begin
  begin
    perform public.vbgramg_simulate_fifo_rebuild(
      '[{"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":20,"linked_waivers":25}]'::jsonb,
      '[]'::jsonb,'[]'::jsonb,false
    );
    raise exception 'Over-waived period unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm = 'Over-waived period unexpectedly accepted' then raise; end if;
  end;
end
$$;

-- Refunds exceeding payment amount are rejected.
do $$
begin
  begin
    perform public.vbgramg_simulate_fifo_rebuild(
      '[]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":10}]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":11}]'::jsonb,
      false
    );
    raise exception 'Over-refunded payment unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm = 'Over-refunded payment unexpectedly accepted' then raise; end if;
  end;
end
$$;

-- Duplicate FIFO order values must be rejected rather than tie-broken by UUID.
do $1
  begin
    perform public.vbgramg_simulate_fifo_rebuild(
      '[
        {"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":10,"linked_waivers":0},
        {"period_id":"00000000-0000-0000-0000-000000000002","period_order":1,"eligible_charges":10,"linked_waivers":0}
      ]'::jsonb,
      '[]'::jsonb,'[]'::jsonb,false
    );
    raise exception 'Duplicate period order unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm = 'Duplicate period order unexpectedly accepted' then raise; end if;
  end;
end
$;

-- Exempt cards receive no allocation proposal.
do $$
declare v_result jsonb;
begin
  v_result := public.vbgramg_simulate_fifo_rebuild(
    '[{"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":100,"linked_waivers":0}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":100}]'::jsonb,
    '[]'::jsonb,true
  );
  if v_result->>'status' <> 'exempt'
     or jsonb_array_length(v_result->'proposed_allocations') <> 0 then
    raise exception 'Exempt rebuild did not return an empty plan: %',v_result;
  end if;
end
$$;

select 'FTO full FIFO rebuild PostgreSQL tests passed' as result;
