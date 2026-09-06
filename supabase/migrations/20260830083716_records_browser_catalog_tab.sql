-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The catalog joins the record browser as its own tab — the one the design called «كتالوج المنصة»
-- and that had nowhere to read from until now. It searches by any recorded name, not just the
-- canonical one: a workshop looking for «صدام امامى» should find the part filed as «صدام أمامي».
create or replace function qvm_new_apps.uploaded_records_get(
  p_kind text default 'stock', p_search text default null, p_make text default null,
  p_limit integer default 100, p_offset integer default 0)
returns jsonb
language plpgsql stable security definer
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
  if p_kind not in ('agency','stock','purchases','aliases','catalog') then
    return jsonb_build_object('status', false, 'message', 'unknown tab', 'data', null);
  end if;
  if not v_team and p_kind <> 'stock' then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'rows', '[]'::jsonb, 'total', 0, 'makes', '[]'::jsonb,
      'counts', jsonb_build_object('agency',0,'stock',0,'purchases',0,'aliases',0,'catalog',0)));
  end if;

  if p_kind = 'catalog' then
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), count(*) over ()
      into v_rows, v_total
      from (
        select jsonb_build_object(
                 'id', c.part_id, 'part_number', c.clean_part_number, 'raw_part_number', c.clean_part_number,
                 'name', c.clean_name_ar, 'name_en', c.clean_name_en,
                 'make', c.clean_make, 'part_class', c.clean_part_class,
                 'country', c.clean_country_manufacture,
                 'is_complete', c.is_complete, 'is_active', c.is_active,
                 -- What is still missing, so the row says why it is not usable yet.
                 'missing', array_to_json(array_remove(array[
                     case when c.clean_part_class is null then 'الصنف' end,
                     case when c.clean_country_manufacture is null
                           and lower(coalesce(c.clean_part_class,'')) not in ('genuine','أصلي')
                          then 'بلد الصنع' end,
                     case when c.clean_name_ar is null then 'الاسم' end], null)),
                 'names', (select count(*) from qvm_new_apps.parts_catalog_names n
                            where n.part_id = c.part_id),
                 'updated_at', c.updated_at) as x,
               c.clean_part_number
          from qvm_new_apps.parts_catalog c
         where (v_q is null
                or c.clean_part_number ilike '%'||v_q||'%'
                or coalesce(c.clean_name_ar,'') ilike '%'||v_q||'%'
                or coalesce(c.clean_name_en,'') ilike '%'||v_q||'%'
                -- any wording anyone has used for it, not only the canonical one
                or exists (select 1 from qvm_new_apps.parts_catalog_names n
                            where n.part_id = c.part_id and n.name ilike '%'||v_q||'%'))
           and (v_make is null or c.clean_make = v_make)
         order by c.clean_part_number
         limit v_lim offset v_off) s;
    select coalesce(jsonb_agg(distinct clean_make), '[]'::jsonb) into v_makes
      from qvm_new_apps.parts_catalog where clean_make is not null;

  elsif p_kind = 'agency' then
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), count(*) over ()
      into v_rows, v_total
      from (
        select jsonb_build_object(
                 'id', a.id, 'part_number', a.clean_part_number, 'raw_part_number', a.source_part_number,
                 'name', a.clean_name, 'raw_name', a.source_name, 'make', a.brand,
                 'part_class', a.part_class,
                 'source', a.source_label,
                 'vendor', v.vendor_name, 'branch', vb.branch_name,
                 'price', a.agency_price,
                 'discount_pct', a.dealer_agency_discount_pct,
                 'price_after_discount', a.agency_price_after_discount,
                 'effective_from', a.effective_from, 'expires_on', a.expires_on,
                 'updated_at', a.updated_at, 'batch_id', a.batch_id) as x,
               a.clean_part_number
          from qvm_new_apps.agency_price_reference a
          left join qvm_new_apps.vendors v on v.vendor_id = a.vendor_id
          left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = a.vendor_branch_id
         where (v_q is null or a.clean_part_number ilike '%'||v_q||'%'
                            or coalesce(a.clean_name,'') ilike '%'||v_q||'%'
                            or coalesce(v.vendor_name,'') ilike '%'||v_q||'%'
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
                 'supplier', h.supplier_name, 'cost', h.cost,
                 'retail_price', h.retail_price, 'before_discount_price', h.before_discount_price,
                 'qty', h.qty, 'cost_on', h.cost_on,
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
      'catalog',   case when v_team then (select count(*) from qvm_new_apps.parts_catalog) else 0 end,
      'agency',    case when v_team then (select count(*) from qvm_new_apps.agency_price_reference) else 0 end,
      'stock',     (select count(*) from qvm_new_apps.inventory_stock i
                     where v_team or i.vendor_id = v_vendor),
      'purchases', case when v_team then (select count(*) from qvm_new_apps.part_purchase_history) else 0 end,
      'aliases',   case when v_team then (select count(*) from qvm_new_apps.part_aliases) else 0 end)));
end
$function$;

grant execute on function qvm_new_apps.uploaded_records_get(text, text, text, integer, integer) to authenticated;
