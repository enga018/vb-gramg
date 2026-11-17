-- Imported FTOs are tracked exclusively in vbgramg_fto_batches.
-- Remove their inspection-state rows so ELIGIBLE always means not yet imported.
-- The trigger also closes the race where an inspection finishes while an import
-- is being committed.

create or replace function public.vbgramg_remove_fto_inspection_after_import()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  delete from public.vbgramg_fto_inspection_state
  where fto_number_normalized =
    upper(regexp_replace(trim(new.fto_number), '[^A-Za-z0-9]', '', 'g'));

  return new;
end;
$$;

drop trigger if exists vbgramg_fto_batches_remove_inspection_after_import
  on public.vbgramg_fto_batches;

create trigger vbgramg_fto_batches_remove_inspection_after_import
after insert or update of fto_number
on public.vbgramg_fto_batches
for each row
execute function public.vbgramg_remove_fto_inspection_after_import();

-- Clean up inspection records for FTOs that were imported before this rule existed.
delete from public.vbgramg_fto_inspection_state s
using public.vbgramg_fto_batches b
where s.fto_number_normalized =
  upper(regexp_replace(trim(b.fto_number), '[^A-Za-z0-9]', '', 'g'))
  and s.classification = 'ELIGIBLE';
