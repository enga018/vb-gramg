-- Isolated PostgreSQL integration test for exemption interval lifecycle.
\set ON_ERROR_STOP on
drop table if exists public.vbgramg_contribution_exemption_history cascade;
drop table if exists public.vbgramg_contribution_exemptions cascade;

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

insert into public.vbgramg_contribution_exemptions
  (job_card_number,note,created_at)
values ('LEGACY/001','Existing active exemption','2026-11-01T10:00:00Z');

\ir ../supabase/migrations/20261111120000_track_contribution_exemption_intervals.sql

do $$
declare
  v_start timestamptz;
  v_end timestamptz;
  v_count integer;
begin
  select started_at into v_start
  from public.vbgramg_contribution_exemption_history
  where job_card_number='LEGACY/001' and ended_at is null;
  if v_start is distinct from '2026-11-01T10:00:00Z'::timestamptz then
    raise exception 'Existing active exemption was not backfilled from its original created_at';
  end if;

  perform public.vbgramg_set_contribution_exemption('NEW/002',true,'temporary',null);
  select count(*) into v_count from public.vbgramg_contribution_exemption_history
    where job_card_number='NEW/002' and ended_at is null;
  if v_count <> 1 then raise exception 'Starting exemption did not open exactly one interval'; end if;

  perform public.vbgramg_set_contribution_exemption('NEW/002',false,'',null);
  select ended_at into v_end from public.vbgramg_contribution_exemption_history
    where job_card_number='NEW/002' and ended_at is not null;
  if v_end is null then raise exception 'Removing exemption did not close its interval'; end if;
  if exists(select 1 from public.vbgramg_contribution_exemptions where job_card_number='NEW/002') then
    raise exception 'Removing exemption did not clear active exemption state';
  end if;

  perform public.vbgramg_set_contribution_exemption('NEW/002',true,'renewed',null);
  select count(*) into v_count from public.vbgramg_contribution_exemption_history
    where job_card_number='NEW/002';
  if v_count <> 2 then raise exception 'Re-exemption did not create a new interval'; end if;
  select count(*) into v_count from public.vbgramg_contribution_exemption_history
    where job_card_number='NEW/002' and ended_at is null;
  if v_count <> 1 then raise exception 'Re-exemption did not leave exactly one open interval'; end if;
end $$;

select 'FTO exemption interval PostgreSQL tests passed' as result;
