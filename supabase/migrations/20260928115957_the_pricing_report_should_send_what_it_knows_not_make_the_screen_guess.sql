-- The pricing report was still answering questions with the shape of its seed data.
--
-- Four things it knew and did not say, and the screen guessed at each of them:
--
-- 1. Whether a purchase resolved to a real vendor. The screen decided this by testing the supplier
--    name against a hard-coded array of five English names left over from the mock data — so every
--    genuinely linked Arabic supplier, «الملحم» included, was drawn with an amber warning and a
--    «Link» button offering to create a vendor that already exists.
-- 2. Which branch a purchase came from. It sent `city` as loose text, from back when that was all a
--    purchase carried.
-- 3. What the purchased row itself was classified as. The ledger's Class column showed the *part's*
--    class on every line, so three purchases of different grades all read the same.
-- 4. Three of the seven classes. genuine/oem/used were mapped and everything else — Aftermarket A,
--    Aftermarket B, Remanufactured — was folded into «Commercial», which is the report asserting a
--    grade nobody recorded.

create or replace function qvm_new_apps.parts_pricing_report_get()
returns jsonb
language plpgsql
stable
security definer
set search_path = qvm_new_apps, public
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
        'partType', qvm_new_apps.part_class_label(c.clean_part_class),
        'make', nullif(btrim(c.clean_make), ''),

        'transactions', coalesce((
          select jsonb_agg(jsonb_build_object(
                   'id', 'h' || p.id,
                   'supplier', coalesce(v.vendor_name, p.supplier_name, '—'),
                   -- The two facts the screen was inventing: whether this name is an account we
                   -- hold, and which one. Null vendorId is the only thing that means «unlinked»;
                   -- a name alone never did.
                   'vendorId', p.vendor_id,
                   'isLinked', p.vendor_id is not null,
                   'date', to_char(p.cost_on, 'YYYY-MM-DD'),
                   'quantity', coalesce(p.qty, 0),
                   'unitPrice', coalesce(p.cost, 0),
                   -- origin records how the row arrived, not where the part was made.
                   'source', case when p.origin = 'external_excel' then 'External Excel'
                                  else 'Internal ERP' end,
                   'branch', qvm_new_apps.branch_ref(p.client_branch_id, p.vendor_branch_id),
                   -- What the file said about this purchase, which is not necessarily what the
                   -- catalogue later settled on for the part.
                   'partClass', qvm_new_apps.part_class_label(p.brand_class),
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
                   -- A discount nobody stated is absent, not zero. «0%» on every agency row is a
                   -- claim that they all quote list, and the screen prints it as one.
                   'discountPct', a.dealer_agency_discount_pct,
                   'branch', qvm_new_apps.branch_ref(a.client_branch_id, a.vendor_branch_id),
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
