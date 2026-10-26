-- Add explicit contribution-month metadata and distinguish each charge round by its date.
alter table public.vbgramg_periods
  add column if not exists contribution_month date;

alter table public.vbgramg_periods
  drop constraint if exists vbgramg_periods_period_date_first_day;

-- Preserve the month already implied by a round date, or infer it from existing month-based names.
update public.vbgramg_periods
set contribution_month = case
  when period_date is not null then date_trunc('month', period_date)::date
  when period_name ~* '^[A-Za-z]+ [0-9]{4}( \([0-9]+\))?$'
    then to_date('01 ' || regexp_replace(period_name, ' \([0-9]+\)$', ''), 'DD Month YYYY')
  else contribution_month
end
where contribution_month is null;

-- For recognizable legacy periods without a round date, use the explicitly named round number,
-- or day 1 for an unsuffixed monthly period.
update public.vbgramg_periods
set period_date = contribution_month + (
  coalesce(nullif(substring(period_name from '\(([0-9]+)\)$'), '')::integer, 1) - 1
)
where period_date is null and contribution_month is not null
  and period_name ~* '^[A-Za-z]+ [0-9]{4}( \([0-9]+\))?$';

alter table public.vbgramg_periods
  add constraint vbgramg_periods_contribution_month_first_day
  check (contribution_month is null or extract(day from contribution_month) = 1);

alter table public.vbgramg_periods
  add constraint vbgramg_periods_round_matches_month
  check (period_date is null or contribution_month is null or date_trunc('month', period_date)::date = contribution_month);

create index if not exists vbgramg_periods_contribution_month_idx
  on public.vbgramg_periods (contribution_month, period_date);

alter table public.vbgramg_charge_ledger
  add column if not exists period_id uuid references public.vbgramg_periods(id) on delete set null;

-- Establish the second May 2026 charge round from the existing MAY26(2) ledger evidence.
insert into public.vbgramg_periods (period_name, period_date, contribution_month, status)
select 'May 2026 (2)', date '2026-05-02', date '2026-05-01', 'open'
where exists (
  select 1 from public.vbgramg_charge_ledger
  where entry_type = 'charge' and charge_period = date '2026-05-01' and note = 'MAY26(2)'
)
and not exists (
  select 1 from public.vbgramg_periods where lower(period_name) = lower('May 2026 (2)')
);

-- Re-link saved FTO batches by their explicit round label, avoiding a month-only guess.
update public.vbgramg_fto_batches b
set period_id = p.id
from public.vbgramg_periods p
where p.contribution_month = b.ledger_charge_period
  and lower(p.period_name) = lower(b.contribution_period);

-- Link legacy monthly ledger rounds using their existing compact labels, with no suffix meaning round 1.
-- Do not alter amounts, charge dates, or notes.
update public.vbgramg_charge_ledger l
set period_id = p.id
from public.vbgramg_periods p
where l.entry_type = 'charge'
  and l.note ~* '^[A-Z]{3}[0-9]{2}(\([0-9]+\))?

  and p.contribution_month = date_trunc('month', to_date('01 ' || substring(l.note from 1 for 3) || ' 20' || substring(l.note from 4 for 2), 'DD MON YYYY'))::date
  and l.charge_period = p.contribution_month
  and lower(p.period_name) = lower(
    to_char(p.contribution_month, 'FMMonth YYYY') ||
    case
      when coalesce(nullif(substring(l.note from '\(([0-9]+)\)
), '')::integer, 1) = 1 then ''
      else ' (' || substring(l.note from '\(([0-9]+)\)
) || ')'
    end
  );
