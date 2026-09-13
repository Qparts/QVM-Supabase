-- The Parts Pricing Report, from the data the uploads actually produced.
--
-- Until now the whole screen ran on SEED_PARTS — eight invented parts in a frontend file, whose
-- own header said «Replace SEED_PARTS with the pricing RPC when the backend is ready». So the
-- report showed «Cabin Air Filter, 520 units» to a system that has never bought one, while the
-- 60 real purchases sitting in part_purchase_history were never looked at.
--
-- One row per part number that has actually been bought, because this is a purchasing report: a
-- part nobody has purchased has no price history to report on. Agency prices join on the same
-- cleaned part number, which is exactly what the cleanup exists to make possible — the purchase
-- file wrote «04465-06090» and the agency file wrote «04465 06090», and they meet here as
-- 0446506090.
create or replace function qvm_new_apps.parts_pricing_report_get()
returns jsonb
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
begin
  if not v_team then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', coalesce((
    select jsonb_agg(part order by part->>'partNumber')
    from (
      select jsonb_build_object(
        'id', 'pn-' || h.clean_part_number,
        'partNumber', h.clean_part_number,
        -- The approved name when the catalogue has one, otherwise whatever the supplier called
        -- it. A part number with no name at all still belongs in the report.
        'description', coalesce(
          nullif(btrim(c.clean_name_ar), ''), nullif(btrim(c.clean_name_en), ''),
          nullif(btrim(h.any_source_name), ''), h.clean_part_number),
        -- The screen's badges. Anything the catalogue has not classified stays 'Unknown' rather
        -- than being filed under one of them: 47 unclassified parts silently labelled
        -- «Commercial» would be the report inventing a fact about every one of them.
        'partType', case lower(coalesce(c.clean_part_class, ''))
                      when 'genuine' then 'Original'
                      when 'أصلي' then 'Original'
                      when 'oem' then 'OEM'
                      when 'used' then 'Used'
                      when '' then 'Unknown'
                      else 'Commercial' end,

        'transactions', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', 'h' || p.id,
                   'supplier', coalesce(v.vendor_name, p.supplier_name, '—'),
                   'date', to_char(p.cost_on, 'YYYY-MM-DD'),
                   'quantity', coalesce(p.qty, 0),
                   'unitPrice', coalesce(p.cost, 0),
                   -- origin records how the row arrived, not where the part was made.
                   'source', case when p.origin = 'external_excel' then 'External Excel'
                                  else 'Internal ERP' end,
                   'city', coalesce(p.city, '—'))
                 order by p.cost_on)
            from qvm_new_apps.part_purchase_history p
            left join qvm_new_apps.vendors v on v.vendor_id = p.vendor_id
           where p.clean_part_number = h.clean_part_number
             and p.cost_on is not null), '[]'::jsonb),

        'agencies', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'agency', coalesce(av.vendor_name, a.source_label, '—'),
                   'netPrice', coalesce(a.agency_price_after_discount, a.agency_price, 0),
                   'listPrice', coalesce(a.agency_price, 0),
                   'discountPct', coalesce(a.dealer_agency_discount_pct, 0),
                   'lastUpdate', to_char(a.updated_at, 'YYYY-MM-DD'))
                 order by coalesce(a.agency_price_after_discount, a.agency_price))
            from qvm_new_apps.agency_price_reference a
            left join qvm_new_apps.vendors av on av.vendor_id = a.vendor_id
           where a.clean_part_number = h.clean_part_number), '[]'::jsonb)
      ) as part
      from (
        select p.clean_part_number,
               max(p.source_name) as any_source_name
          from qvm_new_apps.part_purchase_history p
         where p.clean_part_number is not null
         group by p.clean_part_number
      ) h
      left join qvm_new_apps.parts_catalog c on c.clean_part_number = h.clean_part_number
    ) rows
  ), '[]'::jsonb));
end
$function$;

revoke all on function qvm_new_apps.parts_pricing_report_get() from public;
grant execute on function qvm_new_apps.parts_pricing_report_get() to authenticated;
