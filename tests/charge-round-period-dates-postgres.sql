-- Isolated PostgreSQL regression test for distinct charge-round dates.
-- Run only against a disposable database:
--   createdb vbgramg_charge_round_dates_test
--   PGDATABASE=vbgramg_charge_round_dates_test psql -v ON_ERROR_STOP=1 -f tests/charge-round-period-dates-postgres.sql

CREATE TABLE public.vbgramg_periods (
  id uuid PRIMARY KEY,
  period_name text NOT NULL,
  period_date date,
  contribution_month date,
  CONSTRAINT vbgramg_periods_period_date_first_day
    CHECK (period_date IS NULL OR EXTRACT(DAY FROM period_date) = 1),
  CONSTRAINT vbgramg_periods_contribution_month_first_day
    CHECK (contribution_month IS NULL OR EXTRACT(DAY FROM contribution_month) = 1),
  CONSTRAINT vbgramg_periods_round_matches_month
    CHECK (
      period_date IS NULL OR contribution_month IS NULL
      OR DATE_TRUNC('month', period_date)::date = contribution_month
    )
);

\ir ../supabase/migrations/20261108120000_allow_distinct_charge_round_dates.sql

INSERT INTO public.vbgramg_periods (id, period_name, period_date, contribution_month)
VALUES
  ('00000000-0000-0000-0000-000000000001', 'MAY26',     DATE '2026-05-01', DATE '2026-05-01'),
  ('00000000-0000-0000-0000-000000000002', 'MAY26 (2)', DATE '2026-05-02', DATE '2026-05-01'),
  ('00000000-0000-0000-0000-000000000003', 'MAY26 (3)', DATE '2026-05-03', DATE '2026-05-01');

DO $$
BEGIN
  IF (SELECT count(*) FROM public.vbgramg_periods WHERE contribution_month = DATE '2026-05-01') <> 3 THEN
    RAISE EXCEPTION 'Expected all three May charge rounds to be inserted';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.vbgramg_periods
    WHERE period_name = 'MAY26 (2)' AND period_date = DATE '2026-05-02'
      AND contribution_month = DATE '2026-05-01'
  ) THEN
    RAISE EXCEPTION 'Second charge round did not retain its distinct round date';
  END IF;

  BEGIN
    INSERT INTO public.vbgramg_periods (id, period_name, period_date, contribution_month)
    VALUES ('00000000-0000-0000-0000-000000000004', 'JUN26 wrong date', DATE '2026-05-04', DATE '2026-06-01');
    RAISE EXCEPTION 'Expected a period date from a different month to be rejected';
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.vbgramg_periods'::regclass
      AND conname = 'vbgramg_periods_round_matches_month'
  ) THEN
    RAISE EXCEPTION 'The round/month consistency constraint must remain in place';
  END IF;
END $$;

DROP TABLE public.vbgramg_periods;
