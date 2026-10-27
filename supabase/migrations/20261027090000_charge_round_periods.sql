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
    then to_date('01 ' || substring(period_name from 1 for 3) || ' 20' || substring(period_name from 4 for 2), 'DD MON YYYY')
  else null
end
where contribution_month is null;

-- Legacy rows with no date inherit the month start, not a fabricated round-day suffix.
update public.vbgramg_periods
set period_date = contribution_month
where period_date is null and contribution_month is not null;

alter table public.vbgramg_periods
  drop constraint if exists vbgramg_periods_period_date_first_day;
alter table public.vbgramg_periods
  add constraint vbgramg_periods_period_date_first_day
  check (period_date is null or extract(day from period_date) = 1);
alter table public.vbgramg_periods
  add constraint vbgramg_periods_contribution_month_first_day
  check (contribution_month is null or extract(day from contribution_month) = 1);
alter table public.vbgramg_periods
  add constraint vbgramg_periods_round_matches_month
  check (period_date is null or contribution_month is null or date_trunc('month', period_date)::date = contribution_month);

create index if not exists vbgramg_periods_contribution_month_idx
  on public.vbgramg_periods (contribution_month desc, created_at desc);

alter table public.vbgramg_charge_ledger
  add column if not exists period_id uuid references public.vbgramg_periods(id) on delete set null;
create index if not exists vbgramg_charge_ledger_period_id_idx
  on public.vbgramg_charge_ledger (period_id);

-- Historical FTO batches are linked only when their month maps to exactly one period.
-- Ambiguous legacy records stay unlinked rather than being assigned to the wrong round.
with single_month_period as (
  select contribution_month, min(id::text)::uuid as period_id
  from public.vbgramg_periods
  where contribution_month is not null
  group by contribution_month
  having count(*) = 1
)
update public.vbgramg_fto_batches b
set period_id = s.period_id
from single_month_period s
where b.period_id is null
  and b.ledger_charge_period = s.contribution_month;

-- Link historical charge rows only when their month has one known period.
with single_month_period as (
  select contribution_month, min(id::text)::uuid as period_id
  from public.vbgramg_periods
  where contribution_month is not null
  group by contribution_month
  having count(*) = 1
)
update public.vbgramg_charge_ledger l
set period_id = s.period_id
from single_month_period s
where l.period_id is null
  and l.entry_type = 'charge'
  and l.charge_period = s.contribution_month;


-- Extra contribution charges belong to a specific contribution round, not just a month.
alter table public.vbgramg_contribution_extras
  add column if not exists period_id uuid references public.vbgramg_periods(id) on delete set null;

-- Preserve legacy extras, assigning them only where their month has exactly one period.
with single_month_period as (
  select contribution_month, min(id::text)::uuid as period_id
  from public.vbgramg_periods
  where contribution_month is not null
  group by contribution_month
  having count(*) = 1
)
update public.vbgramg_contribution_extras e
set period_id = s.period_id
from single_month_period s
where e.period_id is null
  and e.charge_period = s.contribution_month;

-- Keep the linked ledger row consistent with the extra's round.
update public.vbgramg_charge_ledger l
set period_id = e.period_id
from public.vbgramg_contribution_extras e
where e.ledger_entry_id = l.id
  and e.period_id is not null
  and l.period_id is null;

-- Remove the old per-job-card/per-month uniqueness so distinct rounds can each hold an extra.
do $$
declare c record;
begin
  for c in
    select con.conname
    from pg_constraint con
    join pg_class rel on rel.oid = con.conrelid
    join pg_namespace ns on ns.oid = rel.relnamespace
    where ns.nspname = 'public'
      and rel.relname = 'vbgramg_contribution_extras'
      and con.contype = 'u'
      and (
        select array_agg(att.attname order by att.attname)
        from unnest(con.conkey) as key(attnum)
        join pg_attribute att on att.attrelid = rel.oid and att.attnum = key.attnum
      ) = array['charge_period','job_card_number']::name[]
  loop
    execute format('alter table public.vbgramg_contribution_extras drop constraint %I', c.conname);
  end loop;
end $$;

drop index if exists public.vbgramg_contribution_extras_job_card_number_charge_period_key;
create unique index if not exists vbgramg_contribution_extras_job_card_period_id_uidx
  on public.vbgramg_contribution_extras (job_card_number, period_id);
