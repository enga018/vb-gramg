-- Enforce the agreed CO parameter rule at the database boundary: whole positive integers only.
create or replace function public.vbgramg_calculate_fto_charges(p_rows jsonb,p_divisor numeric,p_multiplier numeric)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare v_result jsonb;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) < 1 or jsonb_array_length(p_rows) > 5000 then
    raise exception 'FTO calculation rows must be an array containing 1–5,000 items';
  end if;
  if p_divisor is null or p_multiplier is null or p_divisor <= 0 or p_multiplier <= 0
     or p_divisor::text in ('NaN','Infinity','-Infinity') or p_multiplier::text in ('NaN','Infinity','-Infinity')
     or p_divisor <> trunc(p_divisor) or p_multiplier <> trunc(p_multiplier)
     or p_divisor > 1000000000 or p_multiplier > 1000000 then
    raise exception 'FTO divisor and multiplier must be whole positive numbers within the allowed range';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_rows) as r(item)
    where jsonb_typeof(item) <> 'object'
       or coalesce(item->>'row_index','') !~ '^[0-9]+
       or lower(trim(coalesce(item->>'status',''))) not in ('blank','processed','rejected','other')
       or (lower(trim(coalesce(item->>'status',''))) in ('blank','processed')
         and (coalesce(item->>'credit_amount','') !~ '^[0-9]+([.][0-9]+)?
           or case when coalesce(item->>'credit_amount','') ~ '^\d+(\.\d+)?$' then (item->>'credit_amount')::numeric <= 0 else true end))
  ) then raise exception 'An FTO row has an invalid status, row index, or credit amount'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'row_index',(item->>'row_index')::integer,
    'calculated_charge',case
      when lower(trim(item->>'status')) in ('blank','processed') then round(((item->>'credit_amount')::numeric/p_divisor)*p_multiplier,2)
      else 0 end
  ) order by ordinality),'[]'::jsonb)
  into v_result from jsonb_array_elements(p_rows) with ordinality as rows(item,ordinality);

  if exists(select 1 from jsonb_array_elements(v_result) as c(item)
    where (item->>'calculated_charge')::numeric <= 0 or (item->>'calculated_charge')::numeric > 10000000) then
    -- Rejected/other rows legitimately calculate to zero.
    if exists(select 1 from jsonb_array_elements(v_result) as c(item)
      join jsonb_array_elements(p_rows) with ordinality as r(source,ordinality)
        on (r.source->>'row_index')::integer=(c.item->>'row_index')::integer
      where lower(trim(r.source->>'status')) in ('blank','processed')
        and ((c.item->>'calculated_charge')::numeric <= 0 or (c.item->>'calculated_charge')::numeric > 10000000)) then
      raise exception 'An FTO calculated charge is outside the allowed range';
    end if;
  end if;
  return v_result;
end;
$function$;
revoke all on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) from public,anon,authenticated;
grant execute on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) to service_role;

       or lower(trim(coalesce(item->>'status',''))) not in ('blank','processed','rejected','other')
       or (lower(trim(coalesce(item->>'status',''))) in ('blank','processed')
         and (coalesce(item->>'credit_amount','') !~ '^\d+(\.\d+)?$'
           or case when coalesce(item->>'credit_amount','') ~ '^\d+(\.\d+)?$' then (item->>'credit_amount')::numeric <= 0 else true end))
  ) then raise exception 'An FTO row has an invalid status, row index, or credit amount'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'row_index',(item->>'row_index')::integer,
    'calculated_charge',case
      when lower(trim(item->>'status')) in ('blank','processed') then round(((item->>'credit_amount')::numeric/p_divisor)*p_multiplier,2)
      else 0 end
  ) order by ordinality),'[]'::jsonb)
  into v_result from jsonb_array_elements(p_rows) with ordinality as rows(item,ordinality);

  if exists(select 1 from jsonb_array_elements(v_result) as c(item)
    where (item->>'calculated_charge')::numeric <= 0 or (item->>'calculated_charge')::numeric > 10000000) then
    -- Rejected/other rows legitimately calculate to zero.
    if exists(select 1 from jsonb_array_elements(v_result) as c(item)
      join jsonb_array_elements(p_rows) with ordinality as r(source,ordinality)
        on (r.source->>'row_index')::integer=(c.item->>'row_index')::integer
      where lower(trim(r.source->>'status')) in ('blank','processed')
        and ((c.item->>'calculated_charge')::numeric <= 0 or (c.item->>'calculated_charge')::numeric > 10000000)) then
      raise exception 'An FTO calculated charge is outside the allowed range';
    end if;
  end if;
  return v_result;
end;
$function$;
revoke all on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) from public,anon,authenticated;
grant execute on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) to service_role;

           or case when coalesce(item->>'credit_amount','') ~ '^[0-9]+([.][0-9]+)? then (item->>'credit_amount')::numeric <= 0 else true end))
  ) then raise exception 'An FTO row has an invalid status, row index, or credit amount'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'row_index',(item->>'row_index')::integer,
    'calculated_charge',case
      when lower(trim(item->>'status')) in ('blank','processed') then round(((item->>'credit_amount')::numeric/p_divisor)*p_multiplier,2)
      else 0 end
  ) order by ordinality),'[]'::jsonb)
  into v_result from jsonb_array_elements(p_rows) with ordinality as rows(item,ordinality);

  if exists(select 1 from jsonb_array_elements(v_result) as c(item)
    where (item->>'calculated_charge')::numeric <= 0 or (item->>'calculated_charge')::numeric > 10000000) then
    -- Rejected/other rows legitimately calculate to zero.
    if exists(select 1 from jsonb_array_elements(v_result) as c(item)
      join jsonb_array_elements(p_rows) with ordinality as r(source,ordinality)
        on (r.source->>'row_index')::integer=(c.item->>'row_index')::integer
      where lower(trim(r.source->>'status')) in ('blank','processed')
        and ((c.item->>'calculated_charge')::numeric <= 0 or (c.item->>'calculated_charge')::numeric > 10000000)) then
      raise exception 'An FTO calculated charge is outside the allowed range';
    end if;
  end if;
  return v_result;
end;
$function$;
revoke all on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) from public,anon,authenticated;
grant execute on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) to service_role;

       or lower(trim(coalesce(item->>'status',''))) not in ('blank','processed','rejected','other')
       or (lower(trim(coalesce(item->>'status',''))) in ('blank','processed')
         and (coalesce(item->>'credit_amount','') !~ '^\d+(\.\d+)?$'
           or case when coalesce(item->>'credit_amount','') ~ '^\d+(\.\d+)?$' then (item->>'credit_amount')::numeric <= 0 else true end))
  ) then raise exception 'An FTO row has an invalid status, row index, or credit amount'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'row_index',(item->>'row_index')::integer,
    'calculated_charge',case
      when lower(trim(item->>'status')) in ('blank','processed') then round(((item->>'credit_amount')::numeric/p_divisor)*p_multiplier,2)
      else 0 end
  ) order by ordinality),'[]'::jsonb)
  into v_result from jsonb_array_elements(p_rows) with ordinality as rows(item,ordinality);

  if exists(select 1 from jsonb_array_elements(v_result) as c(item)
    where (item->>'calculated_charge')::numeric <= 0 or (item->>'calculated_charge')::numeric > 10000000) then
    -- Rejected/other rows legitimately calculate to zero.
    if exists(select 1 from jsonb_array_elements(v_result) as c(item)
      join jsonb_array_elements(p_rows) with ordinality as r(source,ordinality)
        on (r.source->>'row_index')::integer=(c.item->>'row_index')::integer
      where lower(trim(r.source->>'status')) in ('blank','processed')
        and ((c.item->>'calculated_charge')::numeric <= 0 or (c.item->>'calculated_charge')::numeric > 10000000)) then
      raise exception 'An FTO calculated charge is outside the allowed range';
    end if;
  end if;
  return v_result;
end;
$function$;
revoke all on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) from public,anon,authenticated;
grant execute on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) to service_role;
 then (item->>'credit_amount')::numeric <= 0 else true end))
  ) then raise exception 'An FTO row has an invalid status, row index, or credit amount'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'row_index',(item->>'row_index')::integer,
    'calculated_charge',case
      when lower(trim(item->>'status')) in ('blank','processed') then round(((item->>'credit_amount')::numeric/p_divisor)*p_multiplier,2)
      else 0 end
  ) order by ordinality),'[]'::jsonb)
  into v_result from jsonb_array_elements(p_rows) with ordinality as rows(item,ordinality);

  if exists(select 1 from jsonb_array_elements(v_result) as c(item)
    where (item->>'calculated_charge')::numeric <= 0 or (item->>'calculated_charge')::numeric > 10000000) then
    -- Rejected/other rows legitimately calculate to zero.
    if exists(select 1 from jsonb_array_elements(v_result) as c(item)
      join jsonb_array_elements(p_rows) with ordinality as r(source,ordinality)
        on (r.source->>'row_index')::integer=(c.item->>'row_index')::integer
      where lower(trim(r.source->>'status')) in ('blank','processed')
        and ((c.item->>'calculated_charge')::numeric <= 0 or (c.item->>'calculated_charge')::numeric > 10000000)) then
      raise exception 'An FTO calculated charge is outside the allowed range';
    end if;
  end if;
  return v_result;
end;
$function$;
revoke all on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) from public,anon,authenticated;
grant execute on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) to service_role;

       or lower(trim(coalesce(item->>'status',''))) not in ('blank','processed','rejected','other')
       or (lower(trim(coalesce(item->>'status',''))) in ('blank','processed')
         and (coalesce(item->>'credit_amount','') !~ '^[0-9]+([.][0-9]+)?
           or case when coalesce(item->>'credit_amount','') ~ '^\d+(\.\d+)?$' then (item->>'credit_amount')::numeric <= 0 else true end))
  ) then raise exception 'An FTO row has an invalid status, row index, or credit amount'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'row_index',(item->>'row_index')::integer,
    'calculated_charge',case
      when lower(trim(item->>'status')) in ('blank','processed') then round(((item->>'credit_amount')::numeric/p_divisor)*p_multiplier,2)
      else 0 end
  ) order by ordinality),'[]'::jsonb)
  into v_result from jsonb_array_elements(p_rows) with ordinality as rows(item,ordinality);

  if exists(select 1 from jsonb_array_elements(v_result) as c(item)
    where (item->>'calculated_charge')::numeric <= 0 or (item->>'calculated_charge')::numeric > 10000000) then
    -- Rejected/other rows legitimately calculate to zero.
    if exists(select 1 from jsonb_array_elements(v_result) as c(item)
      join jsonb_array_elements(p_rows) with ordinality as r(source,ordinality)
        on (r.source->>'row_index')::integer=(c.item->>'row_index')::integer
      where lower(trim(r.source->>'status')) in ('blank','processed')
        and ((c.item->>'calculated_charge')::numeric <= 0 or (c.item->>'calculated_charge')::numeric > 10000000)) then
      raise exception 'An FTO calculated charge is outside the allowed range';
    end if;
  end if;
  return v_result;
end;
$function$;
revoke all on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) from public,anon,authenticated;
grant execute on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) to service_role;

           or case when coalesce(item->>'credit_amount','') ~ '^[0-9]+([.][0-9]+)? then (item->>'credit_amount')::numeric <= 0 else true end))
  ) then raise exception 'An FTO row has an invalid status, row index, or credit amount'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'row_index',(item->>'row_index')::integer,
    'calculated_charge',case
      when lower(trim(item->>'status')) in ('blank','processed') then round(((item->>'credit_amount')::numeric/p_divisor)*p_multiplier,2)
      else 0 end
  ) order by ordinality),'[]'::jsonb)
  into v_result from jsonb_array_elements(p_rows) with ordinality as rows(item,ordinality);

  if exists(select 1 from jsonb_array_elements(v_result) as c(item)
    where (item->>'calculated_charge')::numeric <= 0 or (item->>'calculated_charge')::numeric > 10000000) then
    -- Rejected/other rows legitimately calculate to zero.
    if exists(select 1 from jsonb_array_elements(v_result) as c(item)
      join jsonb_array_elements(p_rows) with ordinality as r(source,ordinality)
        on (r.source->>'row_index')::integer=(c.item->>'row_index')::integer
      where lower(trim(r.source->>'status')) in ('blank','processed')
        and ((c.item->>'calculated_charge')::numeric <= 0 or (c.item->>'calculated_charge')::numeric > 10000000)) then
      raise exception 'An FTO calculated charge is outside the allowed range';
    end if;
  end if;
  return v_result;
end;
$function$;
revoke all on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) from public,anon,authenticated;
grant execute on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) to service_role;
 then (item->>'credit_amount')::numeric <= 0 else true end))
  ) then raise exception 'An FTO row has an invalid status, row index, or credit amount'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'row_index',(item->>'row_index')::integer,
    'calculated_charge',case
      when lower(trim(item->>'status')) in ('blank','processed') then round(((item->>'credit_amount')::numeric/p_divisor)*p_multiplier,2)
      else 0 end
  ) order by ordinality),'[]'::jsonb)
  into v_result from jsonb_array_elements(p_rows) with ordinality as rows(item,ordinality);

  if exists(select 1 from jsonb_array_elements(v_result) as c(item)
    where (item->>'calculated_charge')::numeric <= 0 or (item->>'calculated_charge')::numeric > 10000000) then
    -- Rejected/other rows legitimately calculate to zero.
    if exists(select 1 from jsonb_array_elements(v_result) as c(item)
      join jsonb_array_elements(p_rows) with ordinality as r(source,ordinality)
        on (r.source->>'row_index')::integer=(c.item->>'row_index')::integer
      where lower(trim(r.source->>'status')) in ('blank','processed')
        and ((c.item->>'calculated_charge')::numeric <= 0 or (c.item->>'calculated_charge')::numeric > 10000000)) then
      raise exception 'An FTO calculated charge is outside the allowed range';
    end if;
  end if;
  return v_result;
end;
$function$;
revoke all on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) from public,anon,authenticated;
grant execute on function public.vbgramg_calculate_fto_charges(jsonb,numeric,numeric) to service_role;
