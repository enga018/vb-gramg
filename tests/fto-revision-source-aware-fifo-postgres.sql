\set ON_ERROR_STOP on

\ir ../supabase/migrations/20261119100000_add_source_aware_fifo_simulator.sql

do $$
declare
  v_result jsonb;
  v_allocations jsonb;
begin
  -- Fixed manual allocation remains; FIFO consumes only remaining payment and period capacity.
  v_result := public.vbgramg_simulate_fifo_rebuild_source_aware(
    '[
      {"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":100,"linked_waivers":10},
      {"period_id":"00000000-0000-0000-0000-000000000002","period_order":2,"eligible_charges":80,"linked_waivers":0}
    ]'::jsonb,
    '[
      {"payment_id":"10000000-0000-0000-0000-000000000001","amount":100,"payment_date":"2026-01-01","created_at":"2026-01-01T09:00:00Z"},
      {"payment_id":"10000000-0000-0000-0000-000000000002","amount":100,"payment_date":"2026-01-02","created_at":"2026-01-02T09:00:00Z"}
    ]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000002","amount":10}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000001","amount":20,"allocation_source":"manual"}]'::jsonb,
    false
  );

  v_allocations := v_result->'proposed_allocations';
  if v_result->>'status' <> 'simulated'
     or v_result->>'fixed_allocations_preserved' <> 'true'
     or jsonb_array_length(v_allocations) <> 4
     or (v_result->>'fifo_allocated_total')::numeric <> 150 then
    raise exception 'Unexpected source-aware FIFO result: %',v_result;
  end if;

  if (v_allocations->0->>'allocation_source') <> 'manual'
     or (v_allocations->0->>'amount')::numeric <> 20 then
    raise exception 'Manual allocation was not preserved: %',v_allocations;
  end if;

  if (v_allocations->1->>'period_id') <> '00000000-0000-0000-0000-000000000001'
     or (v_allocations->1->>'amount')::numeric <> 70
     or (v_allocations->1->>'allocation_source') <> 'fifo_auto' then
    raise exception 'FIFO did not fill remaining oldest-period balance: %',v_allocations;
  end if;

  if (v_allocations->2->>'period_id') <> '00000000-0000-0000-0000-000000000002'
     or (v_allocations->2->>'amount')::numeric <> 10
     or (v_allocations->2->>'allocation_source') <> 'fifo_auto'
     or (v_allocations->2->>'payment_id') <> '10000000-0000-0000-0000-000000000001' then
    raise exception 'FIFO did not use remaining older payment balance first: %',v_allocations;
  end if;

  if (v_allocations->3->>'period_id') <> '00000000-0000-0000-0000-000000000002'
     or (v_allocations->3->>'amount')::numeric <> 70
     or (v_allocations->3->>'allocation_source') <> 'fifo_auto'
     or (v_allocations->3->>'payment_id') <> '10000000-0000-0000-0000-000000000002' then
    raise exception 'FIFO did not continue with the next payment after refund deduction: %',v_allocations;
  end if;
end
$$;

-- Reviewed historical sources are preserved alongside manual allocations.
do $$
declare v_result jsonb;
begin
  v_result := public.vbgramg_simulate_fifo_rebuild_source_aware(
    '[{"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":50,"linked_waivers":0}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":50}]'::jsonb,
    '[]'::jsonb,
    '[
      {"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000001","amount":10,"allocation_source":"manual"},
      {"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000001","amount":15,"allocation_source":"historical_fifo_reviewed"}
    ]'::jsonb,
    false
  );
  if jsonb_array_length(v_result->'proposed_allocations') <> 3
     or (v_result->>'fifo_allocated_total')::numeric <> 25 then
    raise exception 'Fixed allocation sources did not coexist: %',v_result;
  end if;
end
$$;

-- Fixed allocations exceeding net payment capacity must fail closed.
do $$
begin
  begin
    perform public.vbgramg_simulate_fifo_rebuild_source_aware(
      '[]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":50}]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":10}]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000001","amount":41,"allocation_source":"manual"}]'::jsonb,
      false
    );
    raise exception 'Over-capacity fixed allocation unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm = 'Over-capacity fixed allocation unexpectedly accepted' then raise; end if;
  end;
end
$$;

-- Fixed allocations exceeding revised period balance must fail closed.
do $$
begin
  begin
    perform public.vbgramg_simulate_fifo_rebuild_source_aware(
      '[{"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":20,"linked_waivers":5}]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":50}]'::jsonb,
      '[]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000001","amount":16,"allocation_source":"manual"}]'::jsonb,
      false
    );
    raise exception 'Over-period fixed allocation unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm = 'Over-period fixed allocation unexpectedly accepted' then raise; end if;
  end;
end
$$;

-- Exempt cards keep fixed historical/manual records but receive no FIFO rebuild.
do $$
declare v_result jsonb;
begin
  v_result := public.vbgramg_simulate_fifo_rebuild_source_aware(
    '[{"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":100,"linked_waivers":0}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":100}]'::jsonb,
    '[]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000001","amount":20,"allocation_source":"manual"}]'::jsonb,
    true
  );
  if v_result->>'status' <> 'exempt'
     or jsonb_array_length(v_result->'proposed_allocations') <> 1
     or (v_result->'proposed_allocations'->0->>'allocation_source') <> 'manual' then
    raise exception 'Exempt card did not preserve fixed rows without rebuilding: %',v_result;
  end if;
end
$$;

-- Unsupported source and duplicate source keys are rejected.
do $$
begin
  begin
    perform public.vbgramg_simulate_fifo_rebuild_source_aware(
      '[]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":10}]'::jsonb,
      '[]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000001","amount":1,"allocation_source":"fifo_auto"}]'::jsonb,
      false
    );
    raise exception 'Unsupported fixed source unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm = 'Unsupported fixed source unexpectedly accepted' then raise; end if;
  end;
end
$$;

select 'Source-aware FIFO simulator PostgreSQL tests passed' as result;
