do $migration$
declare
  v_definition text;
  v_old text := $old$^[0-9]+(\\.[0-9]+)?$$old$;
  v_new text := $new$^[0-9]+([.][0-9]+)?$$new$;
begin
  select pg_get_functiondef('public.vbgramg_import_government_fto_history(jsonb, uuid)'::regprocedure)
    into v_definition;
  if length(v_definition) - length(replace(v_definition, v_old, '')) <> 2 * length(v_old) then
    raise exception 'Expected both amount validation expressions were not found exactly twice; aborting correction.';
  end if;
  v_definition := replace(v_definition, v_old, v_new);
  execute v_definition;
end
$migration$;