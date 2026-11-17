-- Serialize inspection writes against FTO batch creation. This prevents an
-- in-flight detail request from recreating inspection state after import cleanup.
-- Both paths acquire the same transaction-scoped advisory lock per normalized FTO.

create or replace function public.vbgramg_lock_fto_batch_identity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-fto:' || upper(btrim(new.fto_number)), 0)
  );
  return new;
end;
$function$;

create or replace function public.vbgramg_prevent_imported_fto_inspection_state()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('vbgramg-fto:' || upper(btrim(new.fto_number_normalized)), 0)
  );

  if exists (
    select 1
    from public.vbgramg_fto_batches b
    where upper(btrim(b.fto_number)) = upper(btrim(new.fto_number_normalized))
  ) then
    return null;
  end if;

  return new;
end;
$function$;

drop trigger if exists vbgramg_lock_fto_batch_identity
  on public.vbgramg_fto_batches;

create trigger vbgramg_lock_fto_batch_identity
before insert or update on public.vbgramg_fto_batches
for each row
execute function public.vbgramg_lock_fto_batch_identity();

drop trigger if exists vbgramg_prevent_imported_fto_inspection_state
  on public.vbgramg_fto_inspection_state;

create trigger vbgramg_prevent_imported_fto_inspection_state
before insert or update on public.vbgramg_fto_inspection_state
for each row
execute function public.vbgramg_prevent_imported_fto_inspection_state();
