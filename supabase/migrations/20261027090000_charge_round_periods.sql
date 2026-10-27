-- Unified monthly periods and charge rounds.
-- Keep existing IDs and period names; use contribution_month for calendar grouping.
alter table public.vbgramg_periods
  add column if not exists contribution_month date;

-- Multiple rounds may share one month label and month-start date.
drop index if exists public.vbgramg_periods_name_ci_uidx;
drop index if exists public.vbgramg_periods_period_date_uidx;

update public.vbgramg_periods
set contribution_month = case
  when period_date is not null then date_trunc('month', period_date)::date
  when period_name ~* '^[A-Za-z]+ [0-9]{4}( \([0-9]+\))?$'
    then to_date('01 ' || regexp_replace(period_name, ' \([0-9]+\)$', ''), 'DD Month YYYY')
  when period_name ~* '^[A-Z]{3}[0-9]{2}( \([0-9]+\))?$'
