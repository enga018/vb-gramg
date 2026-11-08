-- A period's date identifies its round within the calendar month.
-- MAY26 may use May 1 and MAY26 (2) may use May 2; period_id remains
-- the accounting identity. contribution_month remains the month-level reference.
ALTER TABLE public.vbgramg_periods
  DROP CONSTRAINT IF EXISTS vbgramg_periods_period_date_first_day;

COMMENT ON COLUMN public.vbgramg_periods.period_date IS
  'Round date/reference within contribution_month; period_id is the accounting identity.';
