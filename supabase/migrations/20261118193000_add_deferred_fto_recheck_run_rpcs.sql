-- Run lifecycle and per-FTO audit RPCs for deferred Government FTO rechecks.
-- All functions are backend-only and verify the approved administrator identity.

create or replace function public.vbgramg_start_fto_recheck_run(
  p_actor uuid,
  p_total_ftos integer
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text;
  v_run_id uuid;
begin
  if p_actor is null or p_total_ftos is null or p_total_ftos < 0 or p_total_ftos > 10000 then
    raise exception 'Invalid deferred FTO recheck run parameters.';
  end if;

  select lower(u.email) into v_email
  from auth.users u
  where u.id = p_actor;

  if v_email is null or not exists (
    select 1 from public.vbgramg_approved_users a
    where lower(a.email) = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can start a Government FTO recheck.';
  end if;

  insert into public.vbgramg_fto_recheck_runs (actor, total_ftos)
  values (p_actor, p_total_ftos)
  returning id into v_run_id;

  return v_run_id;
end;
$function$;


create or replace function public.vbgramg_recheck_deferred_ftos_with_run(
  p_payload jsonb,
  p_actor uuid,
  p_run_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text;
  v_run public.vbgramg_fto_recheck_runs%rowtype;
  v_result jsonb;
  v_batch_result jsonb;
  v_batch_id uuid;
  v_attempt_count integer;
  v_success_count integer;
begin
  if p_actor is null or p_run_id is null then
    raise exception 'Administrator or recheck run identity is missing.';
  end if;

  select lower(u.email) into v_email
  from auth.users u
  where u.id = p_actor;

  if v_email is null or not exists (
    select 1 from public.vbgramg_approved_users a
    where lower(a.email) = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can recheck Government FTO history.';
  end if;

  select * into v_run
  from public.vbgramg_fto_recheck_runs r
  where r.id = p_run_id
  for update;

  if not found or v_run.actor <> p_actor or v_run.status <> 'running' then
    raise exception 'The deferred FTO recheck run is missing, belongs to another administrator, or is no longer running.';
  end if;

  -- The existing reconciliation RPC validates the complete Government rows and
  -- updates transactions. Its writes and the attempt inserts below share this
  -- PostgreSQL transaction: any error rolls back both.
  v_result := public.vbgramg_recheck_deferred_ftos(p_payload, p_actor);

  if jsonb_typeof(v_result->'batches') is distinct from 'array'
     or jsonb_array_length(v_result->'batches') = 0 then
    raise exception 'The FTO reconciliation returned no per-FTO results.';
  end if;

  for v_batch_result in
    select e.value from jsonb_array_elements(v_result->'batches') as e(value)
  loop
    v_batch_id := nullif(v_batch_result->>'batch_id', '')::uuid;
    if v_batch_id is null or jsonb_typeof(v_batch_result->'result') is distinct from 'object' then
      raise exception 'The FTO reconciliation returned an invalid per-FTO result.';
    end if;

    insert into public.vbgramg_fto_recheck_attempts (
      run_id, batch_id, status, stage, result, actor
    ) values (
      p_run_id, v_batch_id, 'success', 'reconciliation',
      v_batch_result->'result', p_actor
    );
  end loop;

  select count(*)::integer into v_attempt_count
  from public.vbgramg_fto_recheck_attempts a
  where a.run_id = p_run_id;

  select count(*)::integer into v_success_count
  from public.vbgramg_fto_recheck_attempts a
  where a.run_id = p_run_id and a.status = 'success';

  if v_attempt_count > v_run.total_ftos or v_success_count <> v_attempt_count then
    raise exception 'The recheck run has more FTO attempts than its eligible FTO count.';
  end if;

  return v_result;
end;
$function$;


create or replace function public.vbgramg_record_fto_recheck_failure(
  p_run_id uuid,
  p_batch_id uuid,
  p_actor uuid,
  p_stage text,
  p_error_message text
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text;
  v_run public.vbgramg_fto_recheck_runs%rowtype;
  v_message text;
  v_attempt_count integer;
begin
  if p_run_id is null or p_batch_id is null or p_actor is null
     or p_stage not in ('listing_match', 'detail_fetch', 'detail_validation', 'reconciliation') then
    raise exception 'Invalid deferred FTO failure record.';
  end if;

  v_message := nullif(left(btrim(coalesce(p_error_message, '')), 2000), '');
  if v_message is null then
    raise exception 'A concise FTO failure reason is required.';
  end if;

  select lower(u.email) into v_email
  from auth.users u
  where u.id = p_actor;

  if v_email is null or not exists (
    select 1 from public.vbgramg_approved_users a
    where lower(a.email) = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can record a Government FTO recheck failure.';
  end if;

  select * into v_run
  from public.vbgramg_fto_recheck_runs r
  where r.id = p_run_id
  for update;

  if not found or v_run.actor <> p_actor or v_run.status <> 'running' then
    raise exception 'The deferred FTO recheck run is missing, belongs to another administrator, or is no longer running.';
  end if;

  if not exists (
    select 1 from public.vbgramg_fto_batches b where b.id = p_batch_id
  ) then
    raise exception 'The FTO batch for this failed attempt does not exist.';
  end if;

  select count(*)::integer into v_attempt_count
  from public.vbgramg_fto_recheck_attempts a
  where a.run_id = p_run_id;

  if v_attempt_count >= v_run.total_ftos then
    raise exception 'The recheck run already contains all eligible FTO attempts.';
  end if;

  insert into public.vbgramg_fto_recheck_attempts (
    run_id, batch_id, status, stage, error_message, actor
  ) values (
    p_run_id, p_batch_id, 'failed', p_stage, v_message, p_actor
  );

  update public.vbgramg_fto_batches
  set last_deferred_recheck_at = pg_catalog.clock_timestamp(),
      last_deferred_recheck_result = jsonb_build_object(
        'status', 'failed',
        'stage', p_stage,
        'error_message', v_message
      )
  where id = p_batch_id;
end;
$function$;


create or replace function public.vbgramg_complete_fto_recheck_run(
  p_run_id uuid,
  p_actor uuid,
  p_successful_ftos integer,
  p_failed_ftos integer,
  p_status text,
  p_error_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_email text;
  v_run public.vbgramg_fto_recheck_runs%rowtype;
  v_attempted integer;
  v_success integer;
  v_failed integer;
  v_message text;
begin
  if p_run_id is null or p_actor is null
     or p_successful_ftos is null or p_successful_ftos < 0
     or p_failed_ftos is null or p_failed_ftos < 0
     or p_status not in ('completed', 'partial', 'failed') then
    raise exception 'Invalid deferred FTO recheck completion parameters.';
  end if;

  v_message := nullif(left(btrim(coalesce(p_error_message, '')), 2000), '');

  select lower(u.email) into v_email
  from auth.users u
  where u.id = p_actor;

  if v_email is null or not exists (
    select 1 from public.vbgramg_approved_users a
    where lower(a.email) = v_email and a.role = 'admin'
  ) then
    raise exception 'Only an approved VBGRAMG administrator can complete a Government FTO recheck.';
  end if;

  select * into v_run
  from public.vbgramg_fto_recheck_runs r
  where r.id = p_run_id
  for update;

  if not found or v_run.actor <> p_actor or v_run.status <> 'running' then
    raise exception 'The deferred FTO recheck run is missing, belongs to another administrator, or is already finalized.';
  end if;

  select
    count(*)::integer,
    count(*) filter (where a.status = 'success')::integer,
    count(*) filter (where a.status = 'failed')::integer
  into v_attempted, v_success, v_failed
  from public.vbgramg_fto_recheck_attempts a
  where a.run_id = p_run_id;

  if v_success <> p_successful_ftos or v_failed <> p_failed_ftos
     or v_attempted <> v_success + v_failed
     or v_attempted > v_run.total_ftos then
    raise exception 'Recheck run totals do not match the persisted FTO attempt records.';
  end if;

  if p_status = 'completed' and (v_success <> v_run.total_ftos or v_failed <> 0) then
    raise exception 'A completed recheck must successfully check every eligible FTO.';
  elsif p_status = 'partial' and (
    v_success = 0 or v_failed = 0 or v_attempted <> v_run.total_ftos
  ) then
    raise exception 'A partial recheck must record both successful and failed attempts for every eligible FTO.';
  elsif p_status = 'failed' and (
    v_success <> 0 or v_message is null
       or not (v_failed = v_run.total_ftos or v_attempted = 0)
  ) then
    raise exception 'A failed recheck must either fail every eligible FTO or record a run-level failure before any FTO attempts.';
  end if;

  update public.vbgramg_fto_recheck_runs
  set completed_at = pg_catalog.clock_timestamp(),
      status = p_status,
      successful_ftos = v_success,
      failed_ftos = v_failed,
      error_message = v_message
  where id = p_run_id;

  return jsonb_build_object(
    'run_id', p_run_id,
    'status', p_status,
    'total_ftos', v_run.total_ftos,
    'attempted_ftos', v_attempted,
    'successful_ftos', v_success,
    'failed_ftos', v_failed,
    'error_message', v_message
  );
end;
$function$;


revoke all on function public.vbgramg_start_fto_recheck_run(uuid, integer)
  from public, anon, authenticated;
revoke all on function public.vbgramg_recheck_deferred_ftos_with_run(jsonb, uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.vbgramg_record_fto_recheck_failure(uuid, uuid, uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.vbgramg_complete_fto_recheck_run(uuid, uuid, integer, integer, text, text)
  from public, anon, authenticated;

grant execute on function public.vbgramg_start_fto_recheck_run(uuid, integer) to service_role;
grant execute on function public.vbgramg_recheck_deferred_ftos_with_run(jsonb, uuid, uuid) to service_role;
grant execute on function public.vbgramg_record_fto_recheck_failure(uuid, uuid, uuid, text, text) to service_role;
grant execute on function public.vbgramg_complete_fto_recheck_run(uuid, uuid, integer, integer, text, text) to service_role;
