-- Create the next month's base period on the 15th of each month.
-- Supabase Cron uses UTC; 03:30 UTC is 09:00 in Asia/Kolkata.
create extension if not exists pg_cron with schema pg_catalog;

create schema if not exists private;

create or replace function private.create_next_month_vbgramg_period()
returns void
language plpgsql
security definer
set search_path = pg_catalog, public, private
as $$
declare
  target_month date;
  base_period_name text;
begin
  target_month := (
    date_trunc('month', timezone('Asia/Kolkata', now())) + interval '1 month'
  )::date;
  base_period_name := upper(to_char(target_month, 'MONYY'));

  -- Idempotent: if the base period already exists, leave it untouched.
  -- The generic conflict handler also protects against the existing unique
  -- period-name index, without reopening or changing any existing period.
  insert into public.vbgramg_periods (
    period_name,
    period_date,
    contribution_month,
    days,
    status,
    created_by
  )
  values (
    base_period_name,
    target_month,
    target_month,
    null,
    'open',
    null
  )
  on conflict do nothing;
end;
$$;

revoke all on function private.create_next_month_vbgramg_period() from public;
revoke all on function private.create_next_month_vbgramg_period() from anon;
revoke all on function private.create_next_month_vbgramg_period() from authenticated;

-- Replace the named job if this migration is reapplied.
select cron.schedule(
  'vbgramg-create-next-month-period',
  '30 3 15 * *',
  $$select private.create_next_month_vbgramg_period();$$
);
