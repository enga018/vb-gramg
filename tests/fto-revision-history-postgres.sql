\set ON_ERROR_STOP on

-- Isolated schema contract test for FTO revision history.
-- Runs in a dedicated CI database; never connects to the production project.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role;
  end if;
end
$$;

drop table if exists public.vbgramg_fto_revision_history cascade;
drop table if exists public.vbgramg_fto_batches cascade;

create table public.vbgramg_fto_batches (
  id uuid primary key default gen_random_uuid(),
  fto_number text not null unique
);

insert into public.vbgramg_fto_batches (fto_number)
select 'TEST-FTO-' || lpad(n::text, 3, '0')
from generate_series(1, 7) as n;

\ir ../supabase/migrations/20261111105048_add_fto_revision_history.sql

do $$
declare
  v_count integer;
  v_batch_id uuid;
begin
  select count(*) into v_count
  from public.vbgramg_fto_batches
  where revision_number = 1;

  if v_count <> 7 then
    raise exception 'Expected all 7 existing batches to start at revision 1; found %', v_count;
  end if;

  select id into v_batch_id
  from public.vbgramg_fto_batches
  where fto_number = 'TEST-FTO-001';

  -- A valid revision record (revision 2) must be accepted.
  insert into public.vbgramg_fto_revision_history
    (batch_id, revision_number, revision_reason, before_snapshot, after_snapshot)
  values
    (v_batch_id, 2, 'Test revision', '{"state":"before"}', '{"state":"after"}');

  -- Revision 1 is reserved for the original batch state.
  begin
    insert into public.vbgramg_fto_revision_history
      (batch_id, revision_number, revision_reason, before_snapshot, after_snapshot)
    values
      (v_batch_id, 1, 'Invalid first revision', '{}', '{}');
    raise exception 'Revision 1 unexpectedly accepted in revision history';
  exception when check_violation then
    null;
  end;

  -- Revision numbers must be unique per batch.
  begin
    insert into public.vbgramg_fto_revision_history
      (batch_id, revision_number, revision_reason, before_snapshot, after_snapshot)
    values
      (v_batch_id, 2, 'Duplicate revision', '{}', '{}');
    raise exception 'Duplicate batch revision unexpectedly accepted';
  exception when unique_violation then
    null;
  end;

  -- A non-empty reason is mandatory.
  begin
    insert into public.vbgramg_fto_revision_history
      (batch_id, revision_number, revision_reason, before_snapshot, after_snapshot)
    values
      (v_batch_id, 3, '   ', '{}', '{}');
    raise exception 'Blank revision reason unexpectedly accepted';
  exception when check_violation then
    null;
  end;

  -- History must not outlive or point to a nonexistent batch.
  begin
    insert into public.vbgramg_fto_revision_history
      (batch_id, revision_number, revision_reason, before_snapshot, after_snapshot)
    values
      ('00000000-0000-0000-0000-000000000099', 2, 'Missing batch', '{}', '{}');
    raise exception 'Unknown batch reference unexpectedly accepted';
  exception when foreign_key_violation then
    null;
  end;

  if has_table_privilege('anon', 'public.vbgramg_fto_revision_history', 'SELECT')
     or has_table_privilege('authenticated', 'public.vbgramg_fto_revision_history', 'SELECT') then
    raise exception 'Browser roles unexpectedly have SELECT access to revision history';
  end if;

  if not has_table_privilege('service_role', 'public.vbgramg_fto_revision_history', 'SELECT') then
    raise exception 'service_role is missing SELECT access to revision history';
  end if;

  if not (
    select relrowsecurity
    from pg_class
    where oid = 'public.vbgramg_fto_revision_history'::regclass
  ) then
    raise exception 'RLS is not enabled on revision history';
  end if;
end
$$;

select 'FTO revision history PostgreSQL tests passed' as result;
