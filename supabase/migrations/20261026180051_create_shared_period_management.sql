create table if not exists public.vbgramg_periods (
  id uuid primary key default gen_random_uuid(),
  period_name text not null check (length(btrim(period_name)) between 1 and 120),
  period_date date,
  days integer check (days is null or days between 1 and 365),
  status text not null default 'open' check (status in ('open','closed')),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz,
  constraint vbgramg_periods_period_date_first_day check (period_date is null or extract(day from period_date) = 1)
);
create unique index if not exists vbgramg_periods_name_ci_uidx on public.vbgramg_periods (lower(period_name));
create unique index if not exists vbgramg_periods_period_date_uidx on public.vbgramg_periods (period_date) where period_date is not null;
alter table public.vbgramg_periods enable row level security;
revoke all on public.vbgramg_periods from anon, authenticated;
alter table public.vbgramg_demand_runs add column if not exists period_id uuid references public.vbgramg_periods(id) on delete set null;
alter table public.vbgramg_fto_batches add column if not exists period_id uuid references public.vbgramg_periods(id) on delete set null;
insert into public.vbgramg_periods (period_name, period_date, status)
select to_char(month_start, 'FMMonth YYYY'), month_start, 'open'
from (select distinct date_trunc('month', charge_period)::date as month_start from public.vbgramg_charge_ledger where charge_period is not null) months
where month_start is not null on conflict do nothing;
update public.vbgramg_fto_batches b set period_id = p.id from public.vbgramg_periods p where b.period_id is null and b.ledger_charge_period = p.period_date;
