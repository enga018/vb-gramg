-- Enforce a single active deferred FTO recheck run across the application.
-- The partial unique index is the concurrency-safe authority; the RPC converts
-- its conflict into a message suitable for the administrator-facing UI.

create unique index if not exists vbgramg_fto_recheck_one_running_run_idx
  on public.vbgramg_fto_recheck_runs ((status))
  where status = 'running';

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

  begin
    insert into public.vbgramg_fto_recheck_runs (actor, total_ftos)
    values (p_actor, p_total_ftos)
    returning id into v_run_id;
  exception
    when unique_violation then
      raise exception 'A deferred FTO recheck is already in progress. Please wait until it finishes.'
        using errcode = '55P03';
  end;

  return v_run_id;
end;
$function$;

revoke all on function public.vbgramg_start_fto_recheck_run(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.vbgramg_start_fto_recheck_run(uuid, integer)
  to service_role;
