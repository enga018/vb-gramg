create table if not exists public.vbgramg_demand_runs (
  id uuid primary key default gen_random_uuid(),
  period_name text not null check (length(btrim(period_name)) between 1 and 120),
  days integer not null check (days between 1 and 365),
  village_scope text not null default 'New Serchhip North',
  work_demand jsonb not null default '[]'::jsonb check (jsonb_typeof(work_demand) = 'array'),
  unwilling_to_work jsonb not null default '[]'::jsonb check (jsonb_typeof(unwilling_to_work) = 'array'),
  work_demand_count integer not null default 0 check (work_demand_count >= 0),
  unwilling_count integer not null default 0 check (unwilling_count >= 0),
  created_by uuid references auth.users(id) on delete set null,
  created_by_email text not null,
  created_at timestamptz not null default now()
);

create index if not exists vbgramg_demand_runs_created_at_idx
  on public.vbgramg_demand_runs (created_at desc);

alter table public.vbgramg_demand_runs enable row level security;

drop policy if exists "deny direct client access" on public.vbgramg_demand_runs;
create policy "deny direct client access"
  on public.vbgramg_demand_runs
  for all
  to anon, authenticated
  using (false)
  with check (false);

revoke all on table public.vbgramg_demand_runs from anon, authenticated;
grant all on table public.vbgramg_demand_runs to service_role;
