-- Recover interrupted deferred FTO recheck runs without terminating active work.
alter table public.vbgramg_fto_recheck_runs
  add column heartbeat_at timestamptz not null default clock_timestamp();

comment on column public.vbgramg_fto_recheck_runs.heartbeat_at is
  'Last server-side heartbeat; running records older than 30 minutes are eligible for recovery.';

create or replace function public.vbgramg_heartbeat_fto_recheck_run(
  p_run_id uuid,
  p_actor uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text;
begin
  if p_run_id is null or p_actor is null then
    raise exception 'Recheck run identity is missing.';
  end if;

  select lower(u.email) into v_email
  from auth.users u where u.id = p_actor;

  if v_email is null or not exists (
    select 1 from public.vbgramg_approved_users a
    where lower(a.email) = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can heartbeat a Government FTO recheck.';
  end if;

  update public.vbgramg_fto_recheck_runs
  set heartbeat_at = pg_catalog.clock_timestamp()
  where id = p_run_id and actor = p_actor and status = 'running';

  if not found then
    raise exception 'The deferred FTO recheck run is missing or no longer running.';
  end if;
end;
$function$;

create or replace function public.vbgramg_recover_stale_fto_recheck_runs(
  p_actor uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text;
  v_recovered integer;
begin
  if p_actor is null then
    raise exception 'Administrator identity is missing.';
  end if;

  select lower(u.email) into v_email
  from auth.users u where u.id = p_actor;

  if v_email is null or not exists (
    select 1 from public.vbgramg_approved_users a
    where lower(a.email) = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can recover interrupted Government FTO rechecks.';
  end if;

  with stale as (
    select r.id
    from public.vbgramg_fto_recheck_runs r
    where r.status = 'running'
      and r.heartbeat_at < pg_catalog.clock_timestamp() - interval '30 minutes'
    for update skip locked
  ),
  totals as (
    select a.run_id,
      count(*) filter (where a.status = 'success')::integer as successful,
      count(*) filter (where a.status = 'failed')::integer as failed
    from public.vbgramg_fto_recheck_attempts a
    join stale s on s.id = a.run_id
    group by a.run_id
  )
  update public.vbgramg_fto_recheck_runs r
  set status = 'failed',
      completed_at = pg_catalog.clock_timestamp(),
      successful_ftos = coalesce(t.successful, 0),
      failed_ftos = coalesce(t.failed, 0),
      error_message = 'Run stopped sending heartbeats for 30 minutes; marked failed as interrupted.'
  from stale s
  left join totals t on t.run_id = s.id
  where r.id = s.id;

  get diagnostics v_recovered = row_count;
  return v_recovered;
end;
$function$;

revoke all on function public.vbgramg_heartbeat_fto_recheck_run(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.vbgramg_recover_stale_fto_recheck_runs(uuid)
  from public, anon, authenticated;
grant execute on function public.vbgramg_heartbeat_fto_recheck_run(uuid, uuid) to service_role;
grant execute on function public.vbgramg_recover_stale_fto_recheck_runs(uuid) to service_role;
