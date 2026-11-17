-- Import status belongs exclusively to vbgramg_fto_batches.
-- Remove synthetic metadata-only rows created by the earlier import-state backfill.
delete from public.vbgramg_fto_inspection_state s
where s.classification = 'IMPORTED'
  and exists (
    select 1
    from public.vbgramg_fto_batches b
    where upper(btrim(b.fto_number)) = s.fto_number_normalized
      and s.created_at = b.first_imported_at
      and s.last_inspected_at = b.first_imported_at
  );

-- Preserve genuine inspection results; imported FTOs remain ELIGIBLE in the
-- inspection table, while batch history independently prevents refetching.
update public.vbgramg_fto_inspection_state
set classification = 'ELIGIBLE',
    updated_at = now()
where classification = 'IMPORTED';

drop trigger if exists vbgramg_fto_batches_mark_inspection_imported
  on public.vbgramg_fto_batches;

drop function if exists public.vbgramg_mark_fto_inspection_imported();

alter table public.vbgramg_fto_inspection_state
  drop constraint if exists vbgramg_fto_inspection_state_classification_check;

alter table public.vbgramg_fto_inspection_state
  add constraint vbgramg_fto_inspection_state_classification_check
  check (classification in ('RECHECK_REQUIRED', 'ELIGIBLE', 'OUT_OF_SCOPE'));
