alter table public.vbgramg_fto_inspection_state
  drop constraint if exists vbgramg_fto_inspection_state_classification_check;

update public.vbgramg_fto_inspection_state
set classification = 'ELIGIBLE',
    updated_at = now()
where classification = 'COMPLETE';

alter table public.vbgramg_fto_inspection_state
  add constraint vbgramg_fto_inspection_state_classification_check
  check (classification in ('RECHECK_REQUIRED', 'ELIGIBLE', 'OUT_OF_SCOPE'));
