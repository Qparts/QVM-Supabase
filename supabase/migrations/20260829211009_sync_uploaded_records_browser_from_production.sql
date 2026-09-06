-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

create or replace function qvm_new_apps.uploaded_records_get(
  p_kind text default 'stock', p_search text default null, p_make text default null,
  p_limit integer default 100, p_offset integer default 0)
returns jsonb language plpgsql stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_make text := nullif(btrim(coalesce(p_make, '')), '');
  v_lim integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_off integer := greatest(coalesce(p_offset, 0), 0);
  v_rows jsonb := '[]'::jsonb; v_total bigint := 0; v_makes jsonb := '[]'::jsonb;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if p_kind not in ('agency','stock','purchases','aliases') then
    return jsonb_build_object('status', false, 'message', 'unknown tab', 'data', null);
  end if;
  -- Everything but stock is central data; a vendor has no rows of their own in it.
  if not v_team and p_kind <> 'stock' then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'rows', '[]'::jsonb, 'total', 0, 'makes', '[]'::jsonb,
      'counts', jsonb_build_object('agency',0,'stock',0,'purchases',0,'aliases',0)));
  end if;

  if p_kind = 'agency' then
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), count(*) over ()
      into v_rows, v_total
      from (
        select jsonb_build_object(
                 'id', a.id, 'part_number', a.clean_part_number, 'raw_part_number', a.source_part_number,
                 'name', a.clean_name, 'raw_name', a.source_name, 'make', a.brand,
                 'source', a.source_label, 'price', a.agency_price,
                 'effective_from', a.effective_from, 'expires_on', a.expires_on,
                 'updated_at', a.updated_at, 'batch_id', a.batch_id) as x,
               a.clean_part_number
          from qvm_new_apps.agency_price_reference a
         where (v_q is null or a.clean_part_number ilike '%'||v_q||'%'
                            or coalesce(a.clean_name,'') ilike '%'||v_q||'%'
                            or coalesce(a.source_label,'') ilike '%'||v_q||'%')
           and (v_make is null or a.brand = v_make)
         order by a.clean_part_number
         limit v_lim offset v_off) s;
    select coalesce(jsonb_agg(distinct brand), '[]'::jsonb) into v_makes
      from qvm_new_apps.agency_price_reference where brand is not null;

  elsif p_kind = 'stock' then
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), count(*) over ()
      into v_rows, v_total
      from (
        select jsonb_build_object(
                 'id', i.id, 'part_number', i.clean_part_number, 'raw_part_number', i.source_part_number,
                 'name', i.clean_name, 'name_en', i.clean_name_en, 'raw_name', i.source_name,
                 'make', i.brand, 'part_class', i.part_class, 'country', i.country_of_origin,
                 'quantity', i.quantity, 'is_available', i.is_available,
                 'wholesale_price', i.wholesale_price, 'retail_price', i.retail_price,
                 'vendor', v.vendor_name, 'branch', vb.branch_name, 'city', vb.city,
                 'updated_at', i.updated_at, 'batch_id', i.batch_id) as x,
               i.clean_part_number
          from qvm_new_apps.inventory_stock i
          left join qvm_new_apps.vendors v on v.vendor_id = i.vendor_id
          left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = i.vendor_branch_id
         where (v_team or i.vendor_id = v_vendor)
           and (v_q is null or i.clean_part_number ilike '%'||v_q||'%'
                            or coalesce(i.clean_name,'') ilike '%'||v_q||'%'
                            or coalesce(i.clean_name_en,'') ilike '%'||v_q||'%'
                            or coalesce(v.vendor_name,'') ilike '%'||v_q||'%')
           and (v_make is null or i.brand = v_make)
         order by i.clean_part_number
         limit v_lim offset v_off) s;
    select coalesce(jsonb_agg(distinct brand), '[]'::jsonb) into v_makes
      from qvm_new_apps.inventory_stock
     where brand is not null and (v_team or vendor_id = v_vendor);

  elsif p_kind = 'purchases' then
    select coalesce(jsonb_agg(x order by x->>'cost_on' desc), '[]'::jsonb), count(*) over ()
      into v_rows, v_total
      from (
        select jsonb_build_object(
                 'id', h.id, 'part_number', h.clean_part_number, 'raw_part_number', h.source_part_number,
                 'make', h.brand, 'part_class', h.brand_class,
                 'supplier', h.supplier_name, 'cost', h.cost, 'cost_on', h.cost_on,
                 'origin', h.origin, 'batch_id', h.batch_id) as x,
               h.cost_on
          from qvm_new_apps.part_purchase_history h
         where (v_q is null or h.clean_part_number ilike '%'||v_q||'%'
                            or coalesce(h.supplier_name,'') ilike '%'||v_q||'%')
           and (v_make is null or h.brand = v_make)
         order by h.cost_on desc nulls last
         limit v_lim offset v_off) s;
    select coalesce(jsonb_agg(distinct brand), '[]'::jsonb) into v_makes
      from qvm_new_apps.part_purchase_history where brand is not null;

  else
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), count(*) over ()
      into v_rows, v_total
      from (
        select jsonb_build_object(
                 'id', al.id, 'part_number', al.clean_part_number, 'raw_part_number', al.source_part_number,
                 'alias', al.clean_alias, 'raw_alias', al.source_alias,
                 'make', al.brand, 'note', al.note, 'batch_id', al.batch_id) as x,
               al.clean_part_number
          from qvm_new_apps.part_aliases al
         where (v_q is null or al.clean_part_number ilike '%'||v_q||'%'
                            or al.clean_alias ilike '%'||v_q||'%')
           and (v_make is null or al.brand = v_make)
         order by al.clean_part_number
         limit v_lim offset v_off) s;
    select coalesce(jsonb_agg(distinct brand), '[]'::jsonb) into v_makes
      from qvm_new_apps.part_aliases where brand is not null;
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', coalesce(v_total, 0), 'makes', v_makes,
    'counts', jsonb_build_object(
      'agency',    case when v_team then (select count(*) from qvm_new_apps.agency_price_reference) else 0 end,
      'stock',     (select count(*) from qvm_new_apps.inventory_stock i
                     where v_team or i.vendor_id = v_vendor),
      'purchases', case when v_team then (select count(*) from qvm_new_apps.part_purchase_history) else 0 end,
      'aliases',   case when v_team then (select count(*) from qvm_new_apps.part_aliases) else 0 end)));
end
$function$;

create or replace function qvm_new_apps.uploaded_record_update(p_kind text, p_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_n integer := 0;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if p_kind = 'agency' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    update qvm_new_apps.agency_price_reference set
      clean_name     = case when p_patch ? 'name'  then nullif(btrim(p_patch->>'name'),'')  else clean_name end,
      brand          = case when p_patch ? 'make'  then nullif(btrim(p_patch->>'make'),'')  else brand end,
      agency_price   = case when p_patch ? 'price' then nullif(btrim(p_patch->>'price'),'')::numeric else agency_price end,
      effective_from = case when p_patch ? 'effective_from' then nullif(btrim(p_patch->>'effective_from'),'')::date else effective_from end,
      expires_on     = case when p_patch ? 'expires_on' then nullif(btrim(p_patch->>'expires_on'),'')::date else expires_on end,
      updated_at = now()
     where id = p_id;
    get diagnostics v_n = row_count;

  elsif p_kind = 'stock' then
    update qvm_new_apps.inventory_stock i set
      clean_name      = case when p_patch ? 'name'    then nullif(btrim(p_patch->>'name'),'')    else clean_name end,
      clean_name_en   = case when p_patch ? 'name_en' then nullif(btrim(p_patch->>'name_en'),'') else clean_name_en end,
      brand           = case when p_patch ? 'make'    then nullif(btrim(p_patch->>'make'),'')    else brand end,
      part_class      = case when p_patch ? 'part_class' then nullif(btrim(p_patch->>'part_class'),'') else part_class end,
      country_of_origin = case when p_patch ? 'country' then nullif(btrim(p_patch->>'country'),'') else country_of_origin end,
      quantity        = case when p_patch ? 'quantity' then nullif(btrim(p_patch->>'quantity'),'')::integer else quantity end,
      -- Availability follows the quantity unless it was set on purpose: a corrected quantity of 0
      -- that still reads «available» is the kind of row a workshop orders from and never receives.
      is_available    = case when p_patch ? 'is_available' then (p_patch->>'is_available')::boolean
                             when p_patch ? 'quantity' then coalesce(nullif(btrim(p_patch->>'quantity'),'')::integer, 0) > 0
                             else is_available end,
      wholesale_price = case when p_patch ? 'wholesale_price' then nullif(btrim(p_patch->>'wholesale_price'),'')::numeric else wholesale_price end,
      retail_price    = case when p_patch ? 'retail_price' then nullif(btrim(p_patch->>'retail_price'),'')::numeric else retail_price end,
      updated_at = now()
     where i.id = p_id and (v_team or i.vendor_id = v_vendor);
    get diagnostics v_n = row_count;

  elsif p_kind = 'purchases' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    update qvm_new_apps.part_purchase_history set
      supplier_name = case when p_patch ? 'supplier' then nullif(btrim(p_patch->>'supplier'),'') else supplier_name end,
      brand         = case when p_patch ? 'make'     then nullif(btrim(p_patch->>'make'),'')     else brand end,
      brand_class   = case when p_patch ? 'part_class' then nullif(btrim(p_patch->>'part_class'),'') else brand_class end,
      cost          = case when p_patch ? 'cost'     then nullif(btrim(p_patch->>'cost'),'')::double precision else cost end,
      cost_on       = case when p_patch ? 'cost_on'  then nullif(btrim(p_patch->>'cost_on'),'')::date else cost_on end
     where id = p_id;
    get diagnostics v_n = row_count;

  elsif p_kind = 'aliases' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    update qvm_new_apps.part_aliases set
      brand = case when p_patch ? 'make' then nullif(btrim(p_patch->>'make'),'') else brand end,
      note  = case when p_patch ? 'note' then nullif(btrim(p_patch->>'note'),'') else note end
     where id = p_id;
    get diagnostics v_n = row_count;

  else
    return jsonb_build_object('status', false, 'message', 'unknown tab', 'data', null);
  end if;

  if v_n = 0 then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object('id', p_id));
end
$function$;

create or replace function qvm_new_apps.uploaded_record_delete(p_kind text, p_id bigint)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_n integer := 0;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if p_kind = 'stock' then
    delete from qvm_new_apps.inventory_stock i
     where i.id = p_id and (v_team or i.vendor_id = v_vendor);
  elsif not v_team then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  elsif p_kind = 'agency' then
    delete from qvm_new_apps.agency_price_reference where id = p_id;
  elsif p_kind = 'purchases' then
    delete from qvm_new_apps.part_purchase_history where id = p_id;
  elsif p_kind = 'aliases' then
    delete from qvm_new_apps.part_aliases where id = p_id;
  else
    return jsonb_build_object('status', false, 'message', 'unknown tab', 'data', null);
  end if;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object('id', p_id));
end
$function$;

grant execute on function qvm_new_apps.uploaded_records_get(text, text, text, integer, integer) to authenticated;
grant execute on function qvm_new_apps.uploaded_record_update(text, bigint, jsonb) to authenticated;
grant execute on function qvm_new_apps.uploaded_record_delete(text, bigint) to authenticated;
