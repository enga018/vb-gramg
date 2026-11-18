-- Durable audit history for deferred Government FTO recheck operations.
-- A run represents one user-triggered recheck; attempts represent FTOs whose
-- detail data was actually checked after the Government listing was validated.

create table public.vbgramg_fto_recheck_runs (
  id uuid primary key default gen_random_uuid(),
  started_at timestamptz not null default clock_timestamp(),
  completed_at timestamptz,
  status text not null default 'running'
    check (status in ('running', 'completed', 'partial', 'failed')),
  total_ftos integer not null default 0 check (total_ftos >= 0),
  successful_ftos integer not null default 0 check (successful_ftos >= 0),
  failed_ftos integer not null default 0 check (failed_ftos >= 0),
  actor uuid not null references auth.users(id) on delete restrict,
  error_message text,
  constraint vbgramg_fto_recheck_runs_counts_check
    check (successful_ftos + failed_ftos <= total_ftos),
  constraint vbgramg_fto_recheck_runs_completion_check
    check (
      (status = 'running' and completed_at is null)
      or
      (status <> 'running' and completed_at is not null)
    ),
  constraint vbgramg_fto_recheck_runs_error_length_check
    check (error_message is null or length(error_message) <= 2000)
);

comment on table public.vbgramg_fto_recheck_runs is
  'One audit record per administrator-triggered deferred Government FTO recheck run.';
comment on column public.vbgramg_fto_recheck_runs.error_message is
  'Run-level error, such as Government listing fetch or source-validation failure.';

create table public.vbgramg_fto_recheck_attempts (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.vbgramg_fto_recheck_runs(id) on delete restrict,
  batch_id uuid not null references public.vbgramg_fto_batches(id) on delete restrict,
  attempted_at timestamptz not null default clock_timestamp(),
  status text not null check (status in ('success', 'failed')),
  stage text not null
    check (stage in ('listing_match', 'detail_fetch', 'detail_validation', 'reconciliation')),
  result jsonb not null default '{}'::jsonb
    check (jsonb_typeof(result) = 'object'),
  error_message text,
  actor uuid not null references auth.users(id) on delete restrict,
  constraint vbgramg_fto_recheck_attempts_run_batch_unique unique (run_id, batch_id),
  constraint vbgramg_fto_recheck_attempts_error_length_check
    check (error_message is null or length(error_message) <= 2000),
  constraint vbgramg_fto_recheck_attempts_outcome_check
    check (
      (status = 'success' and error_message is null)
      or
      (status = 'failed' and error_message is not null)
    )
);

comment on table public.vbgramg_fto_recheck_attempts is
  'Per-FTO audit records for deferred Government FTO rechecks; no Government HTML is stored.';
comment on column public.vbgramg_fto_recheck_attempts.stage is
  'Stage reached by this FTO attempt: listing_match, detail_fetch, detail_validation, or reconciliation.';
comment on column public.vbgramg_fto_recheck_attempts.result is
  'Successful reconciliation counts, such as updated_count, still_deferred_count, and unchanged_count.';

create index vbgramg_fto_recheck_runs_started_at_idx
  on public.vbgramg_fto_recheck_runs (started_at desc);
create index vbgramg_fto_recheck_attempts_batch_attempted_idx
  on public.vbgramg_fto_recheck_attempts (batch_id, attempted_at desc);
create index vbgramg_fto_recheck_attempts_run_idx
  on public.vbgramg_fto_recheck_attempts (run_id);

-- These audit tables are intentionally backend-only. The Edge Function will
-- access them through narrowly scoped RPCs; no direct Data API grants exist.
alter table public.vbgramg_fto_recheck_runs enable row level security;
alter table public.vbgramg_fto_recheck_attempts enable row level security;

revoke all on table public.vbgramg_fto_recheck_runs
  from public, anon, authenticated, service_role;
revoke all on table public.vbgramg_fto_recheck_attempts
  from public, anon, authenticated, service_role;
