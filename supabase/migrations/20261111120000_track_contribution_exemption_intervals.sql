-- Preserve exemption intervals so FTO transactions first imported while exempt
-- never become chargeable after the exemption is removed.
create table if not exists public.vbgramg_contribution_exemption_history (
  id uuid primary key default gen_random_uuid(),
  job_card_number text not null,
  note text,
  started_at timestamptz not null,
  ended_at timestamptz,
  created_by uuid,
  ended_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vbgramg_contribution_exemption_history_interval_check
    check (ended_at is null or ended_at >= started_at)
);

create index if not exists vbgramg_contribution_exemption_history_card_interval_idx
  on public.vbgramg_contribution_exemption_history (job_card_number, started_at, ended_at);

create unique index if not exists vbgramg_contribution_exemption_history_one_open_idx
  on public.vbgramg_contribution_exemption_history (job_card_number)
  where ended_at is null;

-- This audit history is read and written only by the trusted server-side Edge Function.
alter table public.vbgramg_contribution_exemption_history enable row level security;
revoke all on public.vbgramg_contribution_exemption_history from public, anon, authenticated;
grant select, insert, update, delete on public.vbgramg_contribution_exemption_history to service_role;

-- Existing active exemptions are backfilled using their original creation time.
-- This deliberately does not infer or fabricate historical intervals for exemptions
-- that were already removed before this migration.
insert into public.vbgramg_contribution_exemption_history
  (job_card_number, note, started_at, created_by)
select e.job_card_number, e.note, coalesce(e.created_at, now()), e.created_by
from public.vbgramg_contribution_exemptions e
where not exists (
  select 1 from public.vbgramg_contribution_exemption_history h
  where h.job_card_number = e.job_card_number and h.ended_at is null
)
on conflict do nothing;

create or replace function public.vbgramg_set_contribution_exemption(
  p_job_card_number text,
  p_exempt boolean,
  p_note text,
  p_actor_user_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_card text := pg_catalog.btrim(coalesce(p_job_card_number, ''));
  v_now timestamptz := clock_timestamp();
  v_history_id uuid;
begin
  if v_card = '' or pg_catalog.length(v_card) > 100 then
    raise exception 'A valid full job card number is required';
  end if;
  if p_exempt is null then
    raise exception 'Exemption state is required';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('contribution-exemption:' || v_card, 0)
  );

  if p_exempt then
    insert into public.vbgramg_contribution_exemptions
      (job_card_number, note, created_by, updated_at)
    values (v_card, pg_catalog.left(pg_catalog.btrim(coalesce(p_note,'')),300), p_actor_user_id, v_now)
    on conflict (job_card_number) do update
      set note = excluded.note, updated_at = excluded.updated_at;

    select h.id into v_history_id
    from public.vbgramg_contribution_exemption_history h
    where h.job_card_number = v_card and h.ended_at is null
    order by h.started_at desc
    limit 1;

    if v_history_id is null then
      insert into public.vbgramg_contribution_exemption_history
        (job_card_number, note, started_at, created_by)
      values (v_card, pg_catalog.left(pg_catalog.btrim(coalesce(p_note,'')),300), v_now, p_actor_user_id)
      returning id into v_history_id;
    end if;
  else
    update public.vbgramg_contribution_exemption_history
      set ended_at = v_now, ended_by = p_actor_user_id, updated_at = v_now
    where job_card_number = v_card and ended_at is null;

    delete from public.vbgramg_contribution_exemptions
    where job_card_number = v_card;
  end if;

  return pg_catalog.jsonb_build_object(
    'ok', true, 'job_card_number', v_card, 'exempt', p_exempt,
    'history_id', v_history_id, 'changed_at', v_now
  );
end;
$function$;

revoke all on function public.vbgramg_set_contribution_exemption(text,boolean,text,uuid)
  from public, anon, authenticated;
grant execute on function public.vbgramg_set_contribution_exemption(text,boolean,text,uuid)
  to service_role;

comment on table public.vbgramg_contribution_exemption_history is
  'Immutable exemption intervals used to determine whether an FTO transaction was first seen while its job card was exempt.';
