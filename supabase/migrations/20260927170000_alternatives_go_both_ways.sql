-- Alternatives go both ways.
--
-- The view keyed alternatives on the quotation line's own part number, so a catalogue part that
-- was itself OFFERED as an alternative — 12345, offered instead of p123 — showed nothing, while
-- p123, which no file ever uploaded, held the link. Substitution is symmetric: the part on the
-- line and every alternative offered for it can each stand in for the others. So the group is
-- the line plus its alternatives, and every member lists every other member as its alternative.
--
-- Rows for the line's own part carry the vendor's quoted cost on that line as the price and are
-- labelled as the original on the order; rows for offered alternatives keep their own price,
-- class, brand and origin. The parent's make, class and country still come from the line.

DROP VIEW IF EXISTS qvm_new_apps.part_alternatives_v;
CREATE VIEW qvm_new_apps.part_alternatives_v AS
  WITH lines AS (
    SELECT a.alternative_id, a.source, a.part_number AS alt_pn, a.brand_class AS alt_class_id,
           a.brand_id AS alt_brand_id, a.origin_country_id AS alt_origin_id,
           a.unit_price, a.available_quantity, a.delivery_days, a.note, a.created_at,
           qi.quotation_item_id, qi.part_number AS line_pn, qi.main_brand, qi.brand_class AS line_class_id,
           qi.origin_country_id AS line_origin_id, qi.created_at AS line_created_at,
           qvi.vendor_id, qvi.cost AS line_cost, qvi.origin_country_id AS vendor_origin_id, q.order_number
      FROM qvm_new_apps.quotation_vendor_item_alternatives a
      LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = a.cost_id
      JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = COALESCE(a.quotation_item_id, qvi.quotation_item_id)
      JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
     WHERE COALESCE(btrim(a.part_number), '') <> ''
       AND COALESCE(qvm_new_apps.normalize_part_number(qi.part_number), '') <> ''
  ),
  members AS (
    -- the line's own part, once per line
    (SELECT DISTINCT ON (l.quotation_item_id)
           l.quotation_item_id, 'original'::text AS origin, l.quotation_item_id AS source_id,
           qvm_new_apps.normalize_part_number(l.line_pn) AS pn, l.line_pn AS raw_pn,
           l.line_class_id AS class_id, l.main_brand AS brand_id, COALESCE(l.line_origin_id, l.vendor_origin_id) AS origin_id,
           l.line_cost::numeric AS unit_price, NULL::integer AS available_quantity, NULL::integer AS delivery_days,
           NULL::text AS note, l.line_created_at AS created_at, l.vendor_id, l.order_number,
           l.main_brand AS parent_make_id, l.line_class_id AS parent_class_id, COALESCE(l.line_origin_id, l.vendor_origin_id) AS parent_origin_id
      FROM lines l
     ORDER BY l.quotation_item_id, l.created_at)
    UNION ALL
    -- each alternative offered on it
    SELECT l.quotation_item_id, CASE WHEN l.source = 'qparts' THEN 'qparts' ELSE 'vendor' END, l.alternative_id,
           qvm_new_apps.normalize_part_number(l.alt_pn), l.alt_pn,
           l.alt_class_id, l.alt_brand_id, l.alt_origin_id,
           l.unit_price, l.available_quantity, l.delivery_days,
           l.note, l.created_at, l.vendor_id, l.order_number,
           l.main_brand, l.line_class_id, COALESCE(l.line_origin_id, l.vendor_origin_id)
      FROM lines l
     WHERE COALESCE(qvm_new_apps.normalize_part_number(l.alt_pn), '') <> ''
  )
  SELECT y.origin, y.source_id,
         x.pn AS clean_part_number,
         y.pn AS alt_part_number, y.raw_pn AS raw_alt_part_number,
         CASE y.origin WHEN 'original' THEN 'القطعة الأصلية على الطلب'
                       WHEN 'qparts'   THEN 'بديل من كيوبارتس'
                       ELSE 'بديل من المورد' END::text AS origin_label,
         CASE WHEN y.origin = 'qparts' THEN 'Qparts' ELSE v.vendor_name END::text AS offered_by,
         bc.list_data AS brand_class, br.list_data AS brand, oc.name_ar AS country,
         y.unit_price, y.available_quantity, y.delivery_days,
         y.note, y.order_number, NULL::bigint AS batch_id, y.created_at,
         pm.list_data AS parent_make, pc.list_data AS parent_class, po.name_ar AS parent_country
    FROM members x
    JOIN members y ON y.quotation_item_id = x.quotation_item_id AND y.pn <> x.pn
    LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = y.vendor_id
    LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = y.class_id
    LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = y.brand_id
    LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = y.origin_id
    LEFT JOIN qvm_new_apps.list_data pm ON pm.list_data_id = x.parent_make_id
    LEFT JOIN qvm_new_apps.list_data pc ON pc.list_data_id = x.parent_class_id
    LEFT JOIN qvm_new_apps.origin_countries po ON po.origin_country_id = x.parent_origin_id;
GRANT SELECT ON qvm_new_apps.part_alternatives_v TO service_role;

-- The records function counts distinct alternative numbers per part; body otherwise the live one.
CREATE OR REPLACE FUNCTION qvm_new_apps.uploaded_records_get(p_kind text DEFAULT 'stock'::text, p_search text DEFAULT NULL::text, p_make text DEFAULT NULL::text, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_min_sources integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_make text := nullif(btrim(coalesce(p_make, '')), '');
  v_lim integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_off integer := greatest(coalesce(p_offset, 0), 0);
  v_rows jsonb := '[]'::jsonb; v_total bigint := 0; v_makes jsonb := '[]'::jsonb;
  -- What the stored rows already spell, so a correction can reuse a spelling instead of
  -- inventing a third one.
  v_classes jsonb := '[]'::jsonb; v_countries jsonb := '[]'::jsonb;
  v_min integer := greatest(coalesce(p_min_sources, 0), 0);
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if p_kind not in ('agency','stock','purchases','aliases','catalog','alternatives','purchased') then
    return jsonb_build_object('status', false, 'message', 'unknown tab', 'data', null);
  end if;
  -- A vendor reads their own stock and their own agency prices, and nothing else.
  if not v_team and p_kind not in ('stock', 'agency') then
    return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
      'rows', '[]'::jsonb, 'total', 0, 'makes', '[]'::jsonb,
      'counts', jsonb_build_object('agency',0,'stock',0,'purchases',0,'aliases',0,'catalog',0,'alternatives',0,'purchased',0)));
  end if;

  if p_kind = 'catalog' then
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), coalesce(max(n), 0)
      into v_rows, v_total
      from (
        select count(*) over () as n, jsonb_build_object(
                 'id', c.part_id, 'part_number', c.clean_part_number, 'raw_part_number', c.clean_part_number,
                 'name', c.clean_name_ar, 'name_en', c.clean_name_en,
                 'make', c.clean_make, 'part_class', c.clean_part_class,
                 'country', c.clean_country_manufacture,
                 'is_complete', c.is_complete, 'is_active', c.is_active,
                 'section_id', c.section_id,
                 'section_ar', (select s.name_ar from qvm_new_apps.part_sections s
                                 where s.section_id = c.section_id),
                 'section_en', (select s.name_en from qvm_new_apps.part_sections s
                                 where s.section_id = c.section_id),
                 -- Which of the three tabs holds this number. Ordered, so the badges do not
                 -- reshuffle between two rows that came from the same places.
                 'sources', (select coalesce(jsonb_agg(s order by s), '[]'::jsonb) from (
                     select 'agency' as s where exists (
                       select 1 from qvm_new_apps.agency_price_reference x
                        where x.clean_part_number = c.clean_part_number)
                     union all
                     select 'stock' where exists (
                       select 1 from qvm_new_apps.inventory_stock x
                        where x.clean_part_number = c.clean_part_number)
                     union all
                     select 'purchases' where exists (
                       select 1 from qvm_new_apps.part_purchase_history x
                        where x.clean_part_number = c.clean_part_number)
                     union all
                     -- The part has other numbers it can be bought under: an equivalent number
                     -- from an aliases file, or an alternative a vendor or the buying desk put
                     -- on a quotation line.
                     select 'alternatives' where exists (
                       select 1 from qvm_new_apps.part_alternatives_v x
                        where x.clean_part_number = c.clean_part_number)
                     union all
                     -- Actually bought: a purchase order line in the system, not a purchases file.
                     select 'purchased' where exists (
                       select 1 from qvm_new_apps.part_purchases_v x
                        where x.clean_part_number = c.clean_part_number)
                   ) srcs),
                 -- Every holder of this part, from all three tables at once. The badges above say
                 -- where it was seen; this says what each of them actually holds — which vendor,
                 -- at what price, how many, as of when. The three shapes are unioned into one
                 -- because they are read side by side, and a reader comparing an agency price to
                 -- a purchase cost should not have to re-learn the columns in between.
                 --
                 -- The ids are prefixed strings, not row ids: they identify a line for the page to
                 -- key on, and they deliberately do not look like something to edit here. Each of
                 -- these rows is owned by its own tab, which is where it can be corrected.
                 'children', (
                   select coalesce(jsonb_agg(z order by z->>'source', z->>'holder'), '[]'::jsonb)
                     from (
                       select jsonb_build_object(
                                'id', 'agency-'||a.id, 'source', 'agency',
                                'holder', coalesce(v.vendor_name, a.source_label),
                                -- The customer site this price was uploaded for, not the
                                -- supplier depot. Falls back to the depot for rows written the
                                -- other way round.
                                'branch', coalesce(cbr.branch_name, vb.branch_name),
                                'branch_ref', qvm_new_apps.branch_ref(a.client_branch_id, a.vendor_branch_id),
                                'raw_part_number', a.source_part_number, 'raw_name', a.source_name,
                                'price', a.agency_price,
                                'discount_pct', a.dealer_agency_discount_pct,
                                'price_after_discount', a.agency_price_after_discount,
                                'as_of', a.updated_at,
                                'entry_source', case when a.batch_id is null then 'manual' else 'file' end,
                                'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                                where b.batch_id = a.batch_id)) as z
                         from qvm_new_apps.agency_price_reference a
                         left join qvm_new_apps.vendors v on v.vendor_id = a.vendor_id
                         left join qvm_new_apps.vendor_branches vb
                                on vb.vendor_branch_id = a.vendor_branch_id
                         left join qvm_new_apps.client_branches cbr
                                on cbr.customer_id = a.client_branch_id
                        where a.clean_part_number = c.clean_part_number
                       union all
                       select jsonb_build_object(
                                'id', 'stock-'||i.id, 'source', 'stock',
                                'holder', v.vendor_name, 'branch', vb.branch_name, 'city', vb.city,
                                'branch_ref', qvm_new_apps.branch_ref(null, i.vendor_branch_id),
                                'raw_part_number', i.source_part_number, 'raw_name', i.source_name,
                                'qty', i.quantity, 'is_available', i.is_available,
                                'price', i.wholesale_price, 'retail_price', i.retail_price,
                                'as_of', i.updated_at,
                                'entry_source', case when i.batch_id is null then 'manual' else 'file' end,
                                'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                                where b.batch_id = i.batch_id))
                         from qvm_new_apps.inventory_stock i
                         left join qvm_new_apps.vendors v on v.vendor_id = i.vendor_id
                         left join qvm_new_apps.vendor_branches vb
                                on vb.vendor_branch_id = i.vendor_branch_id
                        where i.clean_part_number = c.clean_part_number
                       union all
                       select jsonb_build_object(
                                'id', 'purchase-'||h.id, 'source', 'purchases',
                                'holder', coalesce(v.vendor_name, h.supplier_name),
                                'branch', null::text, 'city', h.city,
                                'branch_ref', qvm_new_apps.branch_ref(h.client_branch_id, h.vendor_branch_id),
                                'raw_part_number', h.source_part_number, 'raw_name', h.source_name,
                                'qty', h.qty,
                                'price', h.cost, 'retail_price', h.retail_price,
                                'as_of', h.cost_on,
                                'entry_source', case when h.batch_id is null then 'manual' else 'file' end,
                                'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                                where b.batch_id = h.batch_id))
                         from qvm_new_apps.part_purchase_history h
                         left join qvm_new_apps.vendors v on v.vendor_id = h.vendor_id
                        where h.clean_part_number = c.clean_part_number
                       union all
                       -- The alternatives, as lines under the part: the other number, who offered
                       -- it, its class and origin, and the price it was offered at.
                       select jsonb_build_object(
                                'id', 'alternative-'||t.origin||'-'||t.source_id, 'source', 'alternatives',
                                'holder', t.offered_by, 'branch', t.origin_label,
                                'raw_part_number', t.alt_part_number, 'raw_name', t.note,
                                'brand_class', t.brand_class, 'brand', t.brand, 'country', t.country,
                                'qty', t.available_quantity, 'price', t.unit_price,
                                'as_of', t.created_at, 'order_number', t.order_number,
                                'entry_source', case when t.batch_id is null then 'manual' else 'file' end,
                                'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                                where b.batch_id = t.batch_id))
                         from qvm_new_apps.part_alternatives_v t
                        where t.clean_part_number = c.clean_part_number
                       union all
                       -- What was bought on a purchase order: the vendor, the quantity, the unit
                       -- price it was bought at, and where the receipt stands.
                       select jsonb_build_object(
                                'id', 'purchased-'||b.purchase_item_id, 'source', 'purchased',
                                'holder', b.vendor_name, 'branch', b.vendor_branch,
                                'raw_part_number', b.raw_part_number, 'raw_name', b.part_description,
                                'qty', b.approved_qty, 'received_qty', b.received_qty,
                                'price', b.unit_price, 'as_of', b.bought_at,
                                'order_number', b.order_number, 'status', b.status,
                                'entry_source', 'file', 'entry_file', null)
                         from qvm_new_apps.part_purchases_v b
                        where b.clean_part_number = c.clean_part_number
                     ) k),
                 'missing', array_to_json(array_remove(array[
                     -- The make counts as missing now that a part may be held without one. It is
                     -- the first term of the generated is_complete, so leaving it out of this
                     -- list would print «ينقصها: —» beside a row the system calls incomplete.
                     case when c.clean_make is null then 'الماركة' end,
                     case when c.clean_part_class is null then 'الصنف' end,
                     case when c.clean_country_manufacture is null
                           and lower(coalesce(c.clean_part_class,'')) not in ('genuine','أصلي')
                          then 'بلد الصنع' end,
                     case when c.clean_name_ar is null then 'الاسم' end], null)),
                 'names', (select count(*) from qvm_new_apps.parts_catalog_names n
                            where n.part_id = c.part_id),
                 'updated_at', c.updated_at,
                 'entry_source', case when c.source = 'manual' then 'manual' else 'file' end,
                 'entry_file', null) as x,
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
           and (v_min < 2 or (
                 (case when exists (select 1 from qvm_new_apps.agency_price_reference x
                                     where x.clean_part_number = c.clean_part_number)
                       then 1 else 0 end)
               + (case when exists (select 1 from qvm_new_apps.inventory_stock x
                                     where x.clean_part_number = c.clean_part_number)
                       then 1 else 0 end)
               + (case when exists (select 1 from qvm_new_apps.part_purchase_history x
                                     where x.clean_part_number = c.clean_part_number)
                       then 1 else 0 end)) >= v_min)
         order by c.clean_part_number
         limit v_lim offset v_off) s;
    select coalesce(jsonb_agg(distinct clean_make), '[]'::jsonb) into v_makes
      from qvm_new_apps.parts_catalog where clean_make is not null;

  elsif p_kind = 'agency' then
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), coalesce(max(n), 0)
      into v_rows, v_total
      from (
        select g.n, g.clean_part_number as ord, jsonb_build_object(
                 'id', g.clean_part_number,
                 'part_number', g.clean_part_number,
                 -- The catalogue's answer when it has one, the file's wording when it does not.
                 'name', coalesce(pc.clean_name_ar, g.said_name),
                 'name_en', coalesce(pc.clean_name_en, g.said_name_en),
                 'make', coalesce(pc.clean_make, g.said_make),
                 'part_class', coalesce(pc.clean_part_class, g.said_class),
                 'section_ar', (select s.name_ar from qvm_new_apps.part_sections s
                                 where s.section_id = pc.section_id),
                 'section_en', (select s.name_en from qvm_new_apps.part_sections s
                                 where s.section_id = pc.section_id),
                 'lines', g.lines,
                 'min_price', g.min_price, 'max_price', g.max_price,
                 'updated_at', g.updated_at,
                 'entry_source', case when g.from_files = 0 then 'manual' else 'file' end,
                 'entry_file', null,
                 'children', g.children) as x
          from (
            select count(*) over () as n,
                   a.clean_part_number,
                   count(*)              as lines,
                   min(a.agency_price)   as min_price,
                   max(a.agency_price)   as max_price,
                   max(a.updated_at)     as updated_at,
                   count(a.batch_id)     as from_files,
                   (array_agg(a.clean_name order by a.updated_at desc nulls last, a.id desc)
                      filter (where a.clean_name is not null))[1]     as said_name,
                   (array_agg(a.source_name_en order by a.updated_at desc nulls last, a.id desc)
                      filter (where a.source_name_en is not null))[1] as said_name_en,
                   (array_agg(a.brand order by a.updated_at desc nulls last, a.id desc)
                      filter (where a.brand is not null))[1]          as said_make,
                   (array_agg(a.part_class order by a.updated_at desc nulls last, a.id desc)
                      filter (where a.part_class is not null))[1]     as said_class,
                   -- Most recently quoted first: a price list is read from its newest entry.
                   jsonb_agg(jsonb_build_object(
                     'id', a.id,
                     'part_number', a.clean_part_number,
                     'raw_part_number', a.source_part_number,
                     'raw_name', a.source_name, 'raw_name_en', a.source_name_en,
                     'vendor', v.vendor_name,
                     'branch', coalesce(cbr.branch_name, vb.branch_name),
                     'branch_ref', qvm_new_apps.branch_ref(a.client_branch_id, a.vendor_branch_id),
                     -- Carried beside the name so two branches sharing one can still be told
                     -- apart, and so the screen has something stable to group by.
                     'client_branch_id', a.client_branch_id,
                     'source', a.source_label,
                     'make', a.brand, 'part_class', a.part_class,
                     'price', a.agency_price,
                     'discount_pct', a.dealer_agency_discount_pct,
                     'price_after_discount', a.agency_price_after_discount,
                     'effective_from', a.effective_from, 'expires_on', a.expires_on,
                     'updated_at', a.updated_at, 'batch_id', a.batch_id,
                     'entry_source', case when a.batch_id is null then 'manual' else 'file' end,
                     'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                     where b.batch_id = a.batch_id))
                     order by a.updated_at desc nulls last, a.id desc) as children
              from qvm_new_apps.agency_price_reference a
              left join qvm_new_apps.vendors v on v.vendor_id = a.vendor_id
              left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = a.vendor_branch_id
              left join qvm_new_apps.client_branches cbr on cbr.customer_id = a.client_branch_id
             where (v_team or a.vendor_id = v_vendor)
           and (v_q is null or a.clean_part_number ilike '%'||v_q||'%'
                                or coalesce(a.clean_name,'') ilike '%'||v_q||'%'
                                or coalesce(v.vendor_name,'') ilike '%'||v_q||'%'
                                or coalesce(a.source_label,'') ilike '%'||v_q||'%')
               and (v_make is null or a.brand = v_make)
             group by a.clean_part_number
             order by a.clean_part_number
             limit v_lim offset v_off) g
          left join lateral (
            -- One catalogue row, not however many share the number. parts_catalog is unique on
            -- (number, make) with nulls not distinct, so a genuine two-brand part is two rows —
            -- and a plain join would split one group into two and make the count disagree with
            -- the list. A named row wins, then the oldest, so the pick does not wander.
            select pc.* from qvm_new_apps.parts_catalog pc
             where pc.clean_part_number = g.clean_part_number
             order by (pc.clean_name_ar is null), pc.part_id
             limit 1) pc on true) s;
    select coalesce(jsonb_agg(distinct brand), '[]'::jsonb) into v_makes
      from qvm_new_apps.agency_price_reference where brand is not null;

  elsif p_kind = 'stock' then
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), coalesce(max(n), 0)
      into v_rows, v_total
      from (
        select g.n, g.clean_part_number as ord, jsonb_build_object(
                 'id', g.clean_part_number,
                 'part_number', g.clean_part_number,
                 'name', coalesce(pc.clean_name_ar, g.said_name),
                 'name_en', coalesce(pc.clean_name_en, g.said_name_en),
                 'make', coalesce(pc.clean_make, g.said_make),
                 'part_class', coalesce(pc.clean_part_class, g.said_class),
                 'section_ar', (select s.name_ar from qvm_new_apps.part_sections s
                                 where s.section_id = pc.section_id),
                 'section_en', (select s.name_en from qvm_new_apps.part_sections s
                                 where s.section_id = pc.section_id),
                 'lines', g.lines,
                 'total_qty', g.total_qty,
                 -- Available anywhere, which is the only availability a buyer cares about: one
                 -- branch holding it is enough, and five branches at zero is still «not available».
                 'is_available', g.any_available,
                 'min_price', g.min_price, 'max_price', g.max_price,
                 'updated_at', g.updated_at,
                 'entry_source', case when g.from_files = 0 then 'manual' else 'file' end,
                 'entry_file', null,
                 'children', g.children) as x
          from (
            select count(*) over () as n,
                   i.clean_part_number,
                   count(*)                as lines,
                   sum(i.quantity)         as total_qty,
                   bool_or(i.is_available) as any_available,
                   min(i.retail_price)     as min_price,
                   max(i.retail_price)     as max_price,
                   max(i.updated_at)       as updated_at,
                   count(i.batch_id)       as from_files,
                   (array_agg(i.clean_name order by i.updated_at desc nulls last, i.id desc)
                      filter (where i.clean_name is not null))[1]    as said_name,
                   (array_agg(i.clean_name_en order by i.updated_at desc nulls last, i.id desc)
                      filter (where i.clean_name_en is not null))[1] as said_name_en,
                   (array_agg(i.brand order by i.updated_at desc nulls last, i.id desc)
                      filter (where i.brand is not null))[1]         as said_make,
                   (array_agg(i.part_class order by i.updated_at desc nulls last, i.id desc)
                      filter (where i.part_class is not null))[1]    as said_class,
                   -- What is actually in stock first, then the branches that are out of it.
                   jsonb_agg(jsonb_build_object(
                     'id', i.id,
                     'part_number', i.clean_part_number,
                     'raw_part_number', i.source_part_number,
                     'raw_name', i.source_name, 'raw_name_en', i.source_name_en,
                     -- The row's own reading of the part. It is editable on the line — which is
                     -- only possible if the line carries it: a column bound to a key the payload
                     -- never sends reads «—», and saving it sends an empty string, which clears
                     -- the very name it was showing.
                     'name', i.clean_name, 'name_en', i.clean_name_en,
                     'vendor', v.vendor_name, 'branch', vb.branch_name, 'city', vb.city,
                     'branch_ref', qvm_new_apps.branch_ref(null, i.vendor_branch_id),
                     'make', i.brand, 'part_class', i.part_class, 'country', i.country_of_origin,
                     'quantity', i.quantity, 'is_available', i.is_available,
                     'wholesale_price', i.wholesale_price, 'retail_price', i.retail_price,
                     'updated_at', i.updated_at, 'batch_id', i.batch_id,
                     'entry_source', case when i.batch_id is null then 'manual' else 'file' end,
                     'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                     where b.batch_id = i.batch_id))
                     order by i.is_available desc nulls last, i.quantity desc nulls last, i.id desc)
                     as children
              from qvm_new_apps.inventory_stock i
              left join qvm_new_apps.vendors v on v.vendor_id = i.vendor_id
              left join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = i.vendor_branch_id
             -- A vendor still sees only their own rows, and grouping does not widen that: the
             -- filter is applied to the lines, so a part held by two vendors folds into a row
             -- carrying only the lines this caller is allowed to see.
             where (v_team or i.vendor_id = v_vendor)
               and (v_q is null or i.clean_part_number ilike '%'||v_q||'%'
                                or coalesce(i.clean_name,'') ilike '%'||v_q||'%'
                                or coalesce(i.clean_name_en,'') ilike '%'||v_q||'%'
                                or coalesce(v.vendor_name,'') ilike '%'||v_q||'%')
               and (v_make is null or i.brand = v_make)
             group by i.clean_part_number
             order by i.clean_part_number
             limit v_lim offset v_off) g
          left join lateral (
            select pc.* from qvm_new_apps.parts_catalog pc
             where pc.clean_part_number = g.clean_part_number
             order by (pc.clean_name_ar is null), pc.part_id
             limit 1) pc on true) s;
    select coalesce(jsonb_agg(distinct brand), '[]'::jsonb) into v_makes
      from qvm_new_apps.inventory_stock
     where brand is not null and (v_team or vendor_id = v_vendor);

  elsif p_kind = 'purchases' then
    -- One row per part; every purchase of it travels with the row in `children`.
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), coalesce(max(n), 0)
      into v_rows, v_total
      from (
        select g.n, g.clean_part_number as ord, jsonb_build_object(
                 -- The part number is the identity of a group — there is no single row id to give,
                 -- and the ids that exist belong to the lines underneath.
                 'id', g.clean_part_number,
                 'part_number', g.clean_part_number,
                 'name', coalesce(pc.clean_name_ar, g.said_name),
                 'name_en', coalesce(pc.clean_name_en, g.said_name_en),
                 'make', coalesce(pc.clean_make, g.said_make),
                 'part_class', coalesce(pc.clean_part_class, g.said_class),
                 'section_ar', (select s.name_ar from qvm_new_apps.part_sections s
                                 where s.section_id = pc.section_id),
                 'section_en', (select s.name_en from qvm_new_apps.part_sections s
                                 where s.section_id = pc.section_id),
                 'lines', g.lines,
                 'total_qty', g.total_qty,
                 'min_cost', g.min_cost,
                 'max_cost', g.max_cost,
                 'last_cost_on', g.last_cost_on,
                 'updated_at', g.updated_at,
                 -- A part counts as typed by hand only when no line of it arrived in a file.
                 'entry_source', case when g.from_files = 0 then 'manual' else 'file' end,
                 'entry_file', null,
                 'children', g.children) as x
          from (
            select count(*) over () as n,
                   h.clean_part_number,
                   count(*)        as lines,
                   sum(h.qty)      as total_qty,
                   min(h.cost)     as min_cost,
                   max(h.cost)     as max_cost,
                   max(h.cost_on)  as last_cost_on,
                   max(h.created_at) as updated_at,
                   count(h.batch_id) as from_files,
                   -- The most recent wording, not an arbitrary one: if two files spell the part
                   -- differently, the later spelling is the one to show.
                   (array_agg(h.source_name order by h.cost_on desc nulls last, h.id desc)
                      filter (where h.source_name is not null))[1]    as said_name,
                   (array_agg(h.source_name_en order by h.cost_on desc nulls last, h.id desc)
                      filter (where h.source_name_en is not null))[1] as said_name_en,
                   (array_agg(h.brand order by h.cost_on desc nulls last, h.id desc)
                      filter (where h.brand is not null))[1]          as said_make,
                   (array_agg(h.brand_class order by h.cost_on desc nulls last, h.id desc)
                      filter (where h.brand_class is not null))[1]    as said_class,
                   -- Newest purchase first: the last price paid is the one being looked for.
                   jsonb_agg(jsonb_build_object(
                     'id', h.id,
                     'part_number', h.clean_part_number,
                     'raw_part_number', h.source_part_number,
                     'raw_name', h.source_name, 'raw_name_en', h.source_name_en,
                     'supplier', h.supplier_name,
                     -- The vendor the supplier text resolved to, when it resolved to one. Kept
                     -- beside the text rather than replacing it: an unmatched supplier still sold
                     -- us the part, and the file's own wording is the evidence of who that was.
                     'vendor', v.vendor_name,
                     'city', h.city,
                     'make', h.brand, 'part_class', h.brand_class,
                     'branch_ref', qvm_new_apps.branch_ref(h.client_branch_id, h.vendor_branch_id),
                     'qty', h.qty, 'cost', h.cost,
                     'retail_price', h.retail_price,
                     'before_discount_price', h.before_discount_price,
                     'cost_on', h.cost_on, 'origin', h.origin, 'batch_id', h.batch_id,
                     'entry_source', case when h.batch_id is null then 'manual' else 'file' end,
                     'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                     where b.batch_id = h.batch_id))
                     order by h.cost_on desc nulls last, h.id desc) as children
              from qvm_new_apps.part_purchase_history h
              left join qvm_new_apps.vendors v on v.vendor_id = h.vendor_id
             where (v_q is null or h.clean_part_number ilike '%'||v_q||'%'
                                or h.source_part_number ilike '%'||v_q||'%'
                                or coalesce(h.source_name,'') ilike '%'||v_q||'%'
                                or coalesce(h.supplier_name,'') ilike '%'||v_q||'%')
               and (v_make is null or h.brand = v_make)
             -- The window above counts groups, and it is evaluated before the limit — so the
             -- total is the number of parts that match, not the number on this page.
             group by h.clean_part_number
             order by h.clean_part_number
             limit v_lim offset v_off) g
          left join lateral (
            select pc.* from qvm_new_apps.parts_catalog pc
             where pc.clean_part_number = g.clean_part_number
             order by (pc.clean_name_ar is null), pc.part_id
             limit 1) pc on true) s;
    select coalesce(jsonb_agg(distinct brand), '[]'::jsonb) into v_makes
      from qvm_new_apps.part_purchase_history where brand is not null;

  elsif p_kind = 'purchased' then
    -- One row per part bought on a purchase order; every purchase of it travels in `children`.
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), coalesce(max(n), 0)
      into v_rows, v_total
      from (
        select count(*) over () as n, jsonb_build_object(
                 'id', 'bought-'||g.clean_part_number, 'part_number', g.clean_part_number,
                 'raw_part_number', g.clean_part_number,
                 'name', g.part_description, 'make', g.make, 'part_class', g.part_class,
                 'purchases', g.n_lines, 'vendors', g.n_vendors, 'qty', g.qty,
                 'last_price', g.last_price, 'min_price', g.min_price, 'max_price', g.max_price,
                 'as_of', g.last_at,
                 'entry_source', 'file', 'entry_file', null,
                 'children', (
                   select coalesce(jsonb_agg(jsonb_build_object(
                            'id', 'purchased-'||b.purchase_item_id,
                            'order_number', b.order_number, 'purchase_order_id', b.purchase_order_id,
                            'holder', b.vendor_name, 'branch', b.vendor_branch,
                            'raw_part_number', b.raw_part_number, 'raw_name', b.part_description,
                            'qty', b.approved_qty, 'received_qty', b.received_qty, 'returned_qty', b.returned_qty,
                            'price', b.unit_price, 'total', b.line_total,
                            'shipping', b.vendor_shipping_cost,
                            'status', b.status, 'receipt_status', b.receipt_status,
                            'as_of', b.bought_at,
                            'entry_source', 'file', 'entry_file', null)
                          order by b.bought_at desc nulls last, b.purchase_item_id desc), '[]'::jsonb)
                     from qvm_new_apps.part_purchases_v b
                    where b.clean_part_number = g.clean_part_number)) as x,
               g.clean_part_number
          from (select b.clean_part_number,
                       count(*) as n_lines, count(distinct b.vendor_id) as n_vendors,
                       sum(b.approved_qty) as qty,
                       (array_agg(b.unit_price order by b.bought_at desc nulls last, b.purchase_item_id desc)
                          filter (where b.unit_price is not null))[1] as last_price,
                       min(b.unit_price) as min_price, max(b.unit_price) as max_price,
                       max(b.bought_at) as last_at,
                       (array_agg(b.part_description order by b.bought_at desc) filter (where b.part_description is not null))[1] as part_description,
                       (array_agg(b.make order by b.bought_at desc) filter (where b.make is not null))[1] as make,
                       (array_agg(b.part_class order by b.bought_at desc) filter (where b.part_class is not null))[1] as part_class
                  from qvm_new_apps.part_purchases_v b
                 where (v_q is null
                        or b.clean_part_number ilike '%'||v_q||'%'
                        or coalesce(b.part_description,'') ilike '%'||v_q||'%'
                        or coalesce(b.vendor_name,'') ilike '%'||v_q||'%'
                        or coalesce(b.order_number,'') ilike '%'||v_q||'%')
                   and (v_make is null or b.make = v_make)
                 group by b.clean_part_number
                 order by b.clean_part_number
                 limit v_lim offset v_off) g) s;
    select coalesce(jsonb_agg(distinct b.make), '[]'::jsonb) into v_makes
      from qvm_new_apps.part_purchases_v b where b.make is not null;

  elsif p_kind = 'alternatives' then
    -- One row per part that has other numbers it can be bought under; each alternative travels
    -- with the row in `children`, whichever of its three homes it came from.
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), coalesce(max(n), 0)
      into v_rows, v_total
      from (
        select count(*) over () as n, jsonb_build_object(
                 'id', 'alt-'||g.clean_part_number, 'part_number', g.clean_part_number,
                 'raw_part_number', g.clean_part_number,
                 -- The part is described from the quotation line the alternatives were offered
                 -- on — its make, class and origin — because that is where these parts live;
                 -- the catalogue fills in only what the line left blank.
                 'make', coalesce(g.parent_make, (select c.clean_make from qvm_new_apps.parts_catalog c
                           where c.clean_part_number = g.clean_part_number)),
                 'part_class', coalesce(g.parent_class, (select c.clean_part_class from qvm_new_apps.parts_catalog c
                           where c.clean_part_number = g.clean_part_number)),
                 'country', coalesce(g.parent_country, (select c.clean_country_manufacture from qvm_new_apps.parts_catalog c
                           where c.clean_part_number = g.clean_part_number)),
                 'in_catalog', exists (select 1 from qvm_new_apps.parts_catalog c
                                        where c.clean_part_number = g.clean_part_number),
                 'alternatives', g.n_alts,
                 'origins', g.origins,
                 'entry_source', 'file', 'entry_file', null,
                 'children', (
                   select coalesce(jsonb_agg(jsonb_build_object(
                            'id', 'alternative-'||t.origin||'-'||t.source_id,
                            'alt_part_number', t.alt_part_number, 'origin', t.origin,
                            'origin_label', t.origin_label, 'offered_by', t.offered_by,
                            'brand_class', t.brand_class, 'brand', t.brand, 'country', t.country,
                            'unit_price', t.unit_price, 'available_quantity', t.available_quantity,
                            'delivery_days', t.delivery_days, 'note', t.note,
                            'order_number', t.order_number, 'as_of', t.created_at,
                            'entry_source', case when t.batch_id is null then 'manual' else 'file' end,
                            'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                            where b.batch_id = t.batch_id))
                          order by t.created_at desc nulls last), '[]'::jsonb)
                     from qvm_new_apps.part_alternatives_v t
                    where t.clean_part_number = g.clean_part_number)) as x,
               g.clean_part_number
          from (select t.clean_part_number, count(distinct t.alt_part_number) as n_alts,
                       max(t.parent_make) as parent_make, max(t.parent_class) as parent_class,
                       max(t.parent_country) as parent_country,
                       (select coalesce(jsonb_agg(distinct t2.origin), '[]'::jsonb)
                          from qvm_new_apps.part_alternatives_v t2
                         where t2.clean_part_number = t.clean_part_number) as origins
                  from qvm_new_apps.part_alternatives_v t
                 where (v_q is null
                        or t.clean_part_number ilike '%'||v_q||'%'
                        or t.alt_part_number ilike '%'||v_q||'%'
                        or coalesce(t.offered_by,'') ilike '%'||v_q||'%')
                   and (v_make is null or exists (select 1 from qvm_new_apps.parts_catalog c
                                                   where c.clean_part_number = t.clean_part_number
                                                     and c.clean_make = v_make))
                 group by t.clean_part_number
                 order by t.clean_part_number
                 limit v_lim offset v_off) g) s;
    select coalesce(jsonb_agg(distinct c.clean_make), '[]'::jsonb) into v_makes
      from qvm_new_apps.parts_catalog c
     where c.clean_make is not null
       and exists (select 1 from qvm_new_apps.part_alternatives_v t where t.clean_part_number = c.clean_part_number);

  else
    select coalesce(jsonb_agg(x order by x->>'part_number'), '[]'::jsonb), coalesce(max(n), 0)
      into v_rows, v_total
      from (
        select count(*) over () as n, jsonb_build_object(
                 'id', al.id, 'part_number', al.clean_part_number, 'raw_part_number', al.source_part_number,
                 'alias', al.clean_alias, 'raw_alias', al.source_alias,
                 'make', al.brand, 'note', al.note, 'batch_id', al.batch_id,
                 'entry_source', case when al.batch_id is null then 'manual' else 'file' end,
                 'entry_file', (select b.file_name from qvm_new_apps.upload_batches b
                                   where b.batch_id = al.batch_id)) as x,
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

  -- Distinct spellings already in use, across every table that stores one. Trimmed and
  -- de-blanked, because an empty string in a suggestion list is a row nobody can pick.
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into v_classes from (
    select nullif(btrim(part_class), '') as x from qvm_new_apps.agency_price_reference
    union select nullif(btrim(part_class), '') from qvm_new_apps.inventory_stock) q
   where x is not null;

  -- Stock is the only table that records where a part was made.
  select coalesce(jsonb_agg(distinct x), '[]'::jsonb) into v_countries from (
    select nullif(btrim(country_of_origin), '') as x from qvm_new_apps.inventory_stock) q
   where x is not null;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'rows', v_rows, 'total', coalesce(v_total, 0), 'makes', v_makes,
    'classes', v_classes, 'countries', v_countries,
    'counts', jsonb_build_object(
      -- Every cleaned part. What the tab lists is decided by p_min_sources, and this has to
      -- agree with it or the strip contradicts the table underneath it.
      'catalog',   case when v_team then (select count(*) from qvm_new_apps.parts_catalog) else 0 end,
      'agency',    (select count(*) from qvm_new_apps.agency_price_reference a
                      where v_team or a.vendor_id = v_vendor),
      'stock',     (select count(*) from qvm_new_apps.inventory_stock i
                     where v_team or i.vendor_id = v_vendor),
      'purchases', case when v_team then (select count(*) from qvm_new_apps.part_purchase_history) else 0 end,
      'aliases',   case when v_team then (select count(*) from qvm_new_apps.part_aliases) else 0 end,
      -- Parts, not alternatives: the strip counts the rows the tab will show.
      'alternatives', case when v_team then (select count(distinct clean_part_number) from qvm_new_apps.part_alternatives_v) else 0 end,
      'purchased', case when v_team then (select count(distinct clean_part_number) from qvm_new_apps.part_purchases_v) else 0 end)));
end
$function$;
