\set ON_ERROR_STOP on

-- Pure FIFO allocator simulation tests. Dedicated CI database only.
\ir ../supabase/migrations/20261111110537_create_fto_revision_preview.sql

do $$
declare
  v_result jsonb;
  v_allocations jsonb;
  v_total numeric;
begin
  -- Two periods: oldest first. Payment A has ₹20 remaining after its
  -- existing allocation; payment B has ₹100, but ₹10 has been refunded.
  -- Period 1 has ₹50 charges, ₹10 already allocated and ₹5 linked waiver:
  -- due ₹35. Period 2 has ₹40 charges and no prior allocations.
  v_result := public.vbgramg_simulate_fifo_allocator(
    '[
      {"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":50,"linked_waivers":5},
      {"period_id":"00000000-0000-0000-0000-000000000002","period_order":2,"eligible_charges":40,"linked_waivers":0},
      {"period_id":"00000000-0000-0000-0000-000000000099","period_order":3,"eligible_charges":100,"linked_waivers":0}
    ]'::jsonb,
    '[
      {"payment_id":"10000000-0000-0000-0000-000000000001","amount":50,"payment_date":"2026-01-01","created_at":"2026-01-01T09:00:00Z"},
      {"payment_id":"10000000-0000-0000-0000-000000000002","amount":100,"payment_date":"2026-01-02","created_at":"2026-01-02T09:00:00Z"}
    ]'::jsonb,
    '[
      {"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000099","amount":30},
      {"payment_id":"10000000-0000-0000-0000-000000000002","period_id":"00000000-0000-0000-0000-000000000001","amount":10}
    ]'::jsonb,
    '[
      {"payment_id":"10000000-0000-0000-0000-000000000002","amount":10}
    ]'::jsonb,
    false
  );

  v_allocations := v_result->'proposed_allocations';
  v_total := (v_result->>'allocated_total')::numeric;

  if v_total <> 75 then
    raise exception 'Expected simulated allocation total 75; got %', v_total;
  end if;

  if (v_allocations->0->>'payment_id') <> '10000000-0000-0000-0000-000000000001'
     or (v_allocations->0->>'period_id') <> '00000000-0000-0000-0000-000000000001'
     or (v_allocations->0->>'amount')::numeric <> 20 then
    raise exception 'Oldest payment was not allocated first to oldest period: %', v_allocations;
  end if;

  if (v_allocations->1->>'payment_id') <> '10000000-0000-0000-0000-000000000002'
     or (v_allocations->1->>'period_id') <> '00000000-0000-0000-0000-000000000001'
     or (v_allocations->1->>'amount')::numeric <> 15 then
    raise exception 'Second payment did not complete oldest period: %', v_allocations;
  end if;

  if (v_allocations->2->>'period_id') <> '00000000-0000-0000-0000-000000000002'
     or (v_allocations->2->>'amount')::numeric <> 40 then
    raise exception 'Remaining payment credit was not carried to next period: %', v_allocations;
  end if;

  if (v_allocations->3->>'period_id') <> '00000000-0000-0000-0000-000000000099'
     or (v_allocations->3->>'amount')::numeric <> 15 then
    raise exception 'Payment credit was not carried through all periods: %', v_allocations;
  end if;

  -- A revision that leaves existing allocations above the eligible charge
  -- balance must fail closed instead of returning new allocation suggestions.
  v_result := public.vbgramg_simulate_fifo_allocator(
    '[{"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":20,"linked_waivers":0}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":100,"payment_date":"2026-01-01","created_at":"2026-01-01T09:00:00Z"}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000001","amount":25}]'::jsonb,
    '[]'::jsonb,
    false
  );

  if v_result->>'status' <> 'allocation_conflict'
     or jsonb_array_length(v_result->'conflicts') <> 1
     or jsonb_array_length(v_result->'proposed_allocations') <> 0 then
    raise exception 'Over-allocated revision did not fail closed: %', v_result;
  end if;

  -- Exempt cards must never receive proposed allocations.
  v_result := public.vbgramg_simulate_fifo_allocator(
    '[{"period_id":"00000000-0000-0000-0000-000000000001","period_order":1,"eligible_charges":100,"linked_waivers":0}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":100}]'::jsonb,
    '[]'::jsonb,'[]'::jsonb,true
  );

  if v_result->>'status' <> 'exempt'
     or jsonb_array_length(v_result->'proposed_allocations') <> 0 then
    raise exception 'Exempt card was not skipped: %', v_result;
  end if;

  -- Missing snapshot arrays must fail closed.
  begin
    perform public.vbgramg_simulate_fifo_allocator(
      null,'[]'::jsonb,'[]'::jsonb,'[]'::jsonb,false
    );
    raise exception 'NULL snapshot unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm = 'NULL snapshot unexpectedly accepted' then raise; end if;
  end;
end
$$;

select 'FTO FIFO simulation PostgreSQL tests passed' as result;
