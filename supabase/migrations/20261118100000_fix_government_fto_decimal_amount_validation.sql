do $migration$
declare
  v_definition text;
  v_old text := $old$^[0-9]+(\\.[0-9]+)?$$old$;
  v_new text := $new$^[0-9]+([.][0-9]+)?$$new$;
  v_old_count integer;
  v_new_count integer;
begin
  select pg_get_functiondef('public.vbgramg_import_government_fto_history(jsonb, uuid)'::regprocedure)
    into v_definition;
  v_old_count := (length(v_definition) - length(replace(v_definition, v_old, ''))) / length(v_old);
  v_new_count := (length(v_definition) - length(replace(v_definition, v_new, ''))) / length(v_new);
  if v_new_count = 2 and v_old_count = 0 then
    return;
  end if;
  if v_old_count <> 2 then
    raise exception 'Expected two legacy amount validation expressions or two corrected expressions; aborting correction.';
  end if;
  v_definition := replace(v_definition, v_old, v_new);
  execute v_definition;
end
$migration$;