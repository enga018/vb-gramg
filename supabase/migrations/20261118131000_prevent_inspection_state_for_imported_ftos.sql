-- Prevent a late inspection write from recreating ELIGIBLE state after an FTO
-- has already been imported. The batch-side cleanup trigger handles the opposite
-- ordering (inspection write first, import second).

create or replace function public.vbgramg_prevent_inspection_for_imported_fto()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if exists (
    select 1
    from public.vbgramg_fto_batches b
    where upper(regexp_replace(trim(b.fto_number), '[^A-Za-z0-9]', '', 'g')) =
      upper(regexp_replace(trim(new.fto_number), '[^A-Za-z0-9]', '', 'g'))
  ) then
    raise exception 'This FTO has already been imported; inspection state cannot be recorded.';
  end if;

  return new;
end;
$$;

drop trigger if exists vbgramg_fto_inspection_prevent_imported
  on public.vbgramg_fto_inspection_state;

create trigger vbgramg_fto_inspection_prevent_imported
before insert or update
on public.vbgramg_fto_inspection_state
for each row
execute function public.vbgramg_prevent_inspection_for_imported_fto();
