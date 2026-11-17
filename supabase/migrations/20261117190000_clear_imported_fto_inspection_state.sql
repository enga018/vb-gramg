-- Imported FTO batches are the sole source of truth for import status.
-- Remove stale inspection classifications for every already-imported FTO,
-- regardless of whether its Government transactions are Processed, Rejected, or Deferred.

delete from public.vbgramg_fto_inspection_state i
where exists (
  select 1
  from public.vbgramg_fto_batches b
  where upper(btrim(b.fto_number)) = upper(btrim(i.fto_number_normalized))
);

-- Keep the inspection table clean for future imports as well. This runs in the
-- same transaction as the batch insert, so an imported FTO cannot retain a
-- pending inspection tag.
create or replace function public.vbgramg_clear_imported_fto_inspection_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  delete from public.vbgramg_fto_inspection_state
  where fto_number_normalized = upper(btrim(new.fto_number));

  return new;
end;
$function$;

drop trigger if exists vbgramg_clear_imported_fto_inspection_state
  on public.vbgramg_fto_batches;

create trigger vbgramg_clear_imported_fto_inspection_state
after insert or update on public.vbgramg_fto_batches
for each row
execute function public.vbgramg_clear_imported_fto_inspection_state();
