-- Persist the inspected Government transaction rows so an eligible FTO can be
-- prepared for import later without downloading or inspecting its detail page again.
alter table public.vbgramg_fto_inspection_state
  add column if not exists inspection_data jsonb;

alter table public.vbgramg_fto_inspection_state
  drop constraint if exists vbgramg_fto_inspection_state_classification_check;

update public.vbgramg_fto_inspection_state
set classification = 'ELIGIBLE'
where classification in ('COMPLETE', 'RECHECK_REQUIRED');

alter table public.vbgramg_fto_inspection_state
  add constraint vbgramg_fto_inspection_state_classification_check
  check (classification in ('ELIGIBLE', 'OUT_OF_SCOPE'));
