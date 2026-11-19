-- Atomically activate a fully staged official MIS import.
-- The Edge Function performs Government-report parsing and applicant comparison first.
-- This RPC is the single commit point: the active pointer, import status and old-row
-- cleanup either all succeed or all roll back together.

create or replace function public.vbgramg_activate_mis_import(
  p_import_id uuid,
  p_actor_id uuid,
  p_expected_active_import_id uuid,
  p_expected_row_count integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_state public.vbgramg_mis_state%rowtype;
  v_import public.vbgramg_mis_imports%rowtype;
  v_actual_row_count integer;
  v_min_row_number integer;
  v_max_row_number integer;
  v_deleted_row_count integer := 0;
  v_deleted_cache_count integer := 0;
begin
  if p_import_id is null
     or p_actor_id is null
     or p_expected_row_count is null
     or p_expected_row_count < 2 then
    raise exception 'Invalid MIS activation request';
  end if;

  -- Serialize activations and prevent an import compared against a stale baseline
  -- from replacing a newer active MIS.
  select *
    into v_state
  from public.vbgramg_mis_state
  where singleton = true
  for update;

  if not found then
    raise exception 'MIS state record is missing';
  end if;

  if v_state.active_import_id is distinct from p_expected_active_import_id then
    raise exception 'The active MIS changed after comparison. Fetch and compare again; no changes were applied.';
  end if;

  select *
    into v_import
  from public.vbgramg_mis_imports
  where id = p_import_id
  for update;

  if not found
     or v_import.status <> 'staging'
     or v_import.imported_by is distinct from p_actor_id then
    raise exception 'MIS import session is missing, not staged, or belongs to another user';
  end if;

  if v_import.row_count <> p_expected_row_count then
    raise exception 'The staged MIS row count does not match the validated row count';
  end if;

  select count(*)::integer, min(row_number), max(row_number)
    into v_actual_row_count, v_min_row_number, v_max_row_number
  from public.vbgramg_mis_rows
  where import_id = p_import_id;

  if v_actual_row_count <> p_expected_row_count
     or v_min_row_number <> 1
     or v_max_row_number <> p_expected_row_count then
    raise exception 'The staged MIS rows are incomplete or contain a row-number gap. The active MIS was not changed.';
  end if;

  -- Mark the new import complete and switch the active pointer in this transaction.
  update public.vbgramg_mis_imports
  set status = 'complete',
      completed_at = now()
  where id = p_import_id;

  update public.vbgramg_mis_state
  set active_import_id = p_import_id,
      source_filename = v_import.source_filename,
      row_count = p_expected_row_count,
      updated_at = now()
  where singleton = true;

  -- Retain import metadata for the audit trail, but remove cached and row payloads
  -- from every older completed import. Applicant selections are deliberately untouched.
  delete from public.vbgramg_mis_contribution_lookup
  where import_id <> p_import_id;

  get diagnostics v_deleted_cache_count = row_count;

  delete from public.vbgramg_mis_rows r
  using public.vbgramg_mis_imports i
  where r.import_id = i.id
    and i.status = 'complete'
    and i.id <> p_import_id;

  get diagnostics v_deleted_row_count = row_count;

  return jsonb_build_object(
    'success', true,
    'import_id', p_import_id,
    'previous_active_import_id', v_state.active_import_id,
    'row_count', p_expected_row_count,
    'deleted_old_row_count', v_deleted_row_count,
    'deleted_old_cache_count', v_deleted_cache_count,
    'activated_at', now()
  );
end;
$function$;

-- This privileged RPC is called only by the Edge Function's service-role client.
revoke all on function public.vbgramg_activate_mis_import(uuid, uuid, uuid, integer)
  from public, anon, authenticated;
grant execute on function public.vbgramg_activate_mis_import(uuid, uuid, uuid, integer)
  to service_role;
