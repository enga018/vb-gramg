-- Persist only Government transaction details whose Job Cards match the
-- Active MIS snapshot used during inspection. Applicant-name matching is deferred
-- until an administrator opens the FTO from Pending Imports.
alter table public.vbgramg_fto_inspection_state
  add column if not exists validated_transactions jsonb not null default '[]'::jsonb,
  add column if not exists unmatched_transaction_count integer not null default 0,
  add column if not exists active_mis_import_id uuid,
  add column if not exists active_mis_updated_at timestamptz;

alter table public.vbgramg_fto_inspection_state
  drop constraint if exists vbgramg_fto_inspection_state_unmatched_count_check,
  add constraint vbgramg_fto_inspection_state_unmatched_count_check
    check (unmatched_transaction_count >= 0),
  drop constraint if exists vbgramg_fto_inspection_state_validated_transactions_check,
  add constraint vbgramg_fto_inspection_state_validated_transactions_check
    check (jsonb_typeof(validated_transactions) = 'array');

comment on column public.vbgramg_fto_inspection_state.validated_transactions is
  'Validated Government transaction rows whose Job Cards matched the Active MIS snapshot at inspection. Applicant matching is deliberately not performed here. Unmatched personal transaction details are never stored.';
comment on column public.vbgramg_fto_inspection_state.unmatched_transaction_count is
  'Aggregate count of Government transaction rows whose Job Cards did not match Active MIS at inspection; no unmatched personal details are retained.';
comment on column public.vbgramg_fto_inspection_state.active_mis_import_id is
  'Active MIS import ID used for the initial Job Card scope check.';
comment on column public.vbgramg_fto_inspection_state.active_mis_updated_at is
  'Active MIS updated_at timestamp used for the initial Job Card scope check. Pending Imports revalidates against the latest Active MIS before applicant matching.';
