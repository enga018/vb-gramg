\set ON_ERROR_STOP on

DO $roles$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
END $roles$;

\ir ../supabase/migrations/20261119115000_add_charge_level_fifo_simulator.sql

-- Fixed charge-level allocations, legacy period allocations, refunds and
-- period-linked waivers are all deducted before rebuilding automatic FIFO.
do $$
declare v_result jsonb; v_rows jsonb;
begin
  v_result:=public.vbgramg_simulate_charge_level_fifo(
    '[{"charge_id":"00000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","period_order":1,"amount":100,"charge_created_at":"2026-01-01T00:00:00Z"}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":100,"payment_date":"2026-01-01"}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":10}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","charge_id":"00000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","amount":20,"allocation_source":"manual"}]'::jsonb,
    '[]'::jsonb,
    '[{"period_id":"00000000-0000-0000-0000-000000000010","amount":10}]'::jsonb,
    false
  );
  v_rows:=v_result->'proposed_allocations';
  if v_result->>'status'<>'simulated'
     or (v_result->>'fifo_allocated_total')::numeric<>70
     or jsonb_array_length(v_rows)<>2
     or v_rows->1->>'allocation_source'<>'fifo_auto'
     or (v_rows->1->>'amount')::numeric<>70 then
    raise exception 'Charge FIFO did not preserve fixed allocation and deduct refund/waiver: %',v_result;
  end if;
end
$$;

-- A payment present in both allocation systems is ambiguous and rejected.
do $$
begin
  begin
    perform public.vbgramg_simulate_charge_level_fifo(
      '[{"charge_id":"00000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","period_order":1,"amount":100}]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":100}]'::jsonb,
      '[]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","charge_id":"00000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","amount":10,"allocation_source":"manual"}]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","amount":10}]'::jsonb,
      '[]'::jsonb,false
    );
    raise exception 'Ambiguous mixed allocation systems unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm='Ambiguous mixed allocation systems unexpectedly accepted' then raise; end if;
  end;
end
$$;

-- Fixed allocation exceeding a revised charge is rejected.
do $$
begin
  begin
    perform public.vbgramg_simulate_charge_level_fifo(
      '[{"charge_id":"00000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","period_order":1,"amount":10}]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":100}]'::jsonb,
      '[]'::jsonb,
      '[{"payment_id":"10000000-0000-0000-0000-000000000001","charge_id":"00000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","amount":11,"allocation_source":"manual"}]'::jsonb,
      '[]'::jsonb,'[]'::jsonb,false
    );
    raise exception 'Overallocated revised charge unexpectedly accepted';
  exception when raise_exception then
    if sqlerrm='Overallocated revised charge unexpectedly accepted' then raise; end if;
  end;
end
$$;

-- Exempt cards retain fixed allocations and receive no automatic allocation.
do $$
declare v_result jsonb;
begin
  v_result:=public.vbgramg_simulate_charge_level_fifo(
    '[{"charge_id":"00000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","period_order":1,"amount":100}]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","amount":100}]'::jsonb,
    '[]'::jsonb,
    '[{"payment_id":"10000000-0000-0000-0000-000000000001","charge_id":"00000000-0000-0000-0000-000000000001","period_id":"00000000-0000-0000-0000-000000000010","amount":10,"allocation_source":"manual"}]'::jsonb,
    '[]'::jsonb,'[]'::jsonb,true
  );
  if v_result->>'status'<>'exempt'
     or jsonb_array_length(v_result->'proposed_allocations')<>1
     or v_result->'proposed_allocations'->0->>'allocation_source'<>'manual'
     or (v_result->>'fifo_allocated_total')::numeric<>0 then
    raise exception 'Exempt card allocation preservation failed: %',v_result;
  end if;
end
$$;

select 'Charge-level FIFO simulator PostgreSQL tests passed' as result;
