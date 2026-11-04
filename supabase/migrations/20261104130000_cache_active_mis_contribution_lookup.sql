-- Cache the parsed active MIS lookup used by the Contribution page.
-- One immutable cache row per MIS import; a new active import gets a new cache key.
create table if not exists public.vbgramg_mis_contribution_lookup (
  import_id uuid primary key
    references public.vbgramg_mis_imports(id) on delete cascade,
  payload jsonb not null
    check (jsonb_typeof(payload) = 'object'),
  built_at timestamptz not null default now()
);

alter table public.vbgramg_mis_contribution_lookup enable row level security;

comment on table public.vbgramg_mis_contribution_lookup is
  'Server-only, versioned parsed household/applicant lookup for Contribution startup. Rebuilt automatically when an active MIS import has no cache.';
