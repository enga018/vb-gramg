-- Normalize stored period names to compact month-and-round labels.
-- Keep period IDs and all foreign-key relationships unchanged.
with ranked_periods as (
  select
    id,
    contribution_month,
    case extract(month from contribution_month)::int
      when 1 then 'JAN' when 2 then 'FEB' when 3 then 'MAR'
      when 4 then 'APR' when 5 then 'MAY' when 6 then 'JUN'
      when 7 then 'JUL' when 8 then 'AUG' when 9 then 'SEP'
      when 10 then 'OCT' when 11 then 'NOV' when 12 then 'DEC'
    end || to_char(contribution_month, 'YY') as base_name,
    row_number() over (
      partition by contribution_month
      order by created_at asc nulls first, id asc
    ) as round_number
  from public.vbgramg_periods
  where contribution_month is not null
),
renamed_periods as (
  select
    id,
    case when round_number = 1 then base_name
      else base_name || ' (' || round_number::text || ')'
    end as new_name
  from ranked_periods
)
update public.vbgramg_periods p
set period_name = r.new_name,
    updated_at = now()
from renamed_periods r
where p.id = r.id
  and p.period_name is distinct from r.new_name;

-- Keep saved Work Demand snapshots consistent with the canonical period name.
update public.vbgramg_demand_runs d
set period_name = p.period_name
from public.vbgramg_periods p
where d.period_id = p.id
  and d.period_name is distinct from p.period_name;

-- Prevent duplicate compact names if two demand saves race for the same month.
create unique index if not exists vbgramg_periods_compact_name_ci_uidx
  on public.vbgramg_periods (lower(period_name))
  where contribution_month is not null;
