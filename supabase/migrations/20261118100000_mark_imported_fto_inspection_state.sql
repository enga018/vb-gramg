-- Keep inspection classification aligned with successful Government FTO imports.
alter table public.vbgramg_fto_inspection_state
  drop constraint if exists vbgramg_fto_inspection_state_classification_check;

update public.vbgramg_fto_inspection_state s
set classification = 'IMPORTED',
    updated_at = now()
where exists (
  select 1
  from public.vbgramg_fto_batches b
  where upper(btrim(b.fto_number)) = upper(btrim(s.fto_number))
);

alter table public.vbgramg_fto_inspection_state
  add constraint vbgramg_fto_inspection_state_classification_check
  check (classification in ('RECHECK_REQUIRED', 'ELIGIBLE', 'OUT_OF_SCOPE', 'IMPORTED'));

create or replace function public.vbgramg_mark_fto_inspection_imported()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.vbgramg_fto_inspection_state
  set classification = 'IMPORTED',
      updated_at = now()
  where upper(btrim(fto_number)) = upper(btrim(new.fto_number));

  return new;
end;
$$;

drop trigger if exists vbgramg_fto_batches_mark_inspection_imported
  on public.vbgramg_fto_batches;

create trigger vbgramg_fto_batches_mark_inspection_imported
after insert on public.vbgramg_fto_batches
for each row
execute function public.vbgramg_mark_fto_inspection_imported();
