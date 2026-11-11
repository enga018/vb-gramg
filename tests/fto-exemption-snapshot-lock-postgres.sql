-- Apply the real exemption and snapshot migrations in an isolated PostgreSQL database.
-- Exercise the snapshot RPC's database-side guard before any financial writes.
\set ON_ERROR_STOP on

do $$
begin
  if not exists (select 1 from pg_roles where rolname='anon') then create role anon; end if;
  if not exists (select 1 from pg_roles where rolname='authenticated') then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname='service_role') then create role service_role; end if;
end $$;

create table public.vbgramg_contribution_exemptions (
  job_card_number text primary key,
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

\ir ../supabase/migrations/20261111120000_track_contribution_exemption_intervals.sql

create table public.vbgramg_fto_transactions (
  id uuid primary key,
  created_at timestamptz
);

create table public.vbgramg_charge_ledger (
  id uuid primary key,
  entry_type text,
  note text,
  job_card_number text,
  period_id uuid,
  charge_period date
);

\ir ../supabase/migrations/20261111160000_serialize_fto_snapshot_with_exemptions.sql

insert into public.vbgramg_contribution_exemption_history
  (job_card_number, started_at, ended_at)
values
  ('CARD/DURING', '2026-11-10T00:00:00Z', '2026-11-12T00:00:00Z'),
  ('CARD/UNKNOWN', '2026-11-01T00:00:00Z', '2026-11-02T00:00:00Z');

do $$
declare
  v_plan jsonb;
  v_rejected boolean;
begin
  -- Known first-seen timestamp overlaps a closed exemption interval.
  v_plan := jsonb_build_object(
    'batch', jsonb_build_object('fto_number','TEST-DURING'),
    'charge_import', jsonb_build_object(),
    'manual_charge_link_ids', '[]'::jsonb,
    'transactions', jsonb_build_array(jsonb_build_object(
      'id','10000000-0000-0000-0000-000000000001',
      'job_card_number','CARD/DURING',
      'reference_no','REF-DURING',
      'created_at','2026-11-11T10:00:00Z',
      'is_in_scope',true
    )),
    'ledger_rows', jsonb_build_array(jsonb_build_object(
      'job_card_number','CARD/DURING',
      'reference_numbers',jsonb_build_array('REF-DURING')
    ))
  );
  v_rejected := false;
  begin
    perform public.vbgramg_apply_fto_snapshot(v_plan);
  exception when sqlstate '23514' then
    if sqlerrm not like 'FTO snapshot rejected:%' then raise; end if;
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'Snapshot with first-seen timestamp inside exemption was not rejected'; end if;

  -- Missing first-seen timestamp is fail-closed even when the interval has ended.
  v_plan := jsonb_set(v_plan, '{batch,fto_number}', '"TEST-UNKNOWN"');
  v_plan := jsonb_set(v_plan, '{transactions,0,id}', '"10000000-0000-0000-0000-000000000002"');
  v_plan := jsonb_set(v_plan, '{transactions,0,job_card_number}', '"CARD/UNKNOWN"');
  v_plan := jsonb_set(v_plan, '{transactions,0,reference_no}', '"REF-UNKNOWN"');
  v_plan := v_plan #- '{transactions,0,created_at}';
  v_plan := jsonb_set(v_plan, '{ledger_rows,0,job_card_number}', '"CARD/UNKNOWN"');
  v_plan := jsonb_set(v_plan, '{ledger_rows,0,reference_numbers}', '["REF-UNKNOWN"]');
  v_rejected := false;
  begin
    perform public.vbgramg_apply_fto_snapshot(v_plan);
  exception when sqlstate '23514' then
    if sqlerrm not like 'FTO snapshot rejected:%' then raise; end if;
    v_rejected := true;
  end;
  if not v_rejected then raise exception 'Snapshot with missing first-seen timestamp and exemption history was not rejected'; end if;
end $$;

select 'FTO snapshot exemption PostgreSQL integration tests passed' as result;
