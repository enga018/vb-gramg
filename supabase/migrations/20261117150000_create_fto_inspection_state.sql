create table if not exists public.vbgramg_fto_inspection_state (
  fto_number_normalized text primary key,
  fto_number text not null,
  classification text not null
    check (classification in ('RECHECK_REQUIRED', 'COMPLETE', 'OUT_OF_SCOPE')),
  last_inspected_at timestamptz not null default now(),
  matching_job_card_count integer not null default 0
    check (matching_job_card_count >= 0),
  deferred_transaction_count integer not null default 0
    check (deferred_transaction_count >= 0),
  transaction_count integer not null default 0
    check (transaction_count >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vbgramg_fto_inspection_state_normalized_check
    check (fto_number_normalized = upper(btrim(fto_number_normalized)) and fto_number_normalized <> '')
);

create index if not exists vbgramg_fto_inspection_state_classification_idx
  on public.vbgramg_fto_inspection_state (classification, last_inspected_at desc);

alter table public.vbgramg_fto_inspection_state enable row level security;
revoke all on public.vbgramg_fto_inspection_state from anon, authenticated;
grant all on public.vbgramg_fto_inspection_state to service_role;
