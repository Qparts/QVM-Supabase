-- Every tab lists parts, not rows — and the catalogue learns to open.
--
-- 20260916120042 folded past purchases; this finishes the idea. An agency price list repeats the
-- part once per vendor and a stock list once per branch, so the fields that identify a part —
-- number, name, make, class — are drawn over and over while the three that actually differ are
-- pushed off the right-hand edge. Comparing two vendors' prices for one part meant scrolling
-- sideways, which is the wrong shape for the only question these tables exist to answer.
--
-- The catalogue already listed one row per part, so nothing folds there. What it lacked was the
-- other half: it said a part had been seen in agency, stock and purchases without ever saying what
-- any of them said about it. Now the row carries every holder from all three tables at once, so
-- «who has this and for how much» is a click instead of three tabs and three searches.
--
-- Past purchases is re-stated here as well, for one reason worth its own paragraph: parts_catalog
-- may legitimately hold the same number twice, once per make, and 20260916120042 joined it
-- plainly. A two-brand part therefore split back into two rows and the count disagreed with the
-- list — the fold undone by the very table it was reading names from. Every branch below joins the
-- catalogue laterally and takes one row.
--
-- Four targeted patches rather than one rewrite: uploaded_records_get carries five tabs, and
-- restating the whole body is how a fix in a branch nobody is touching quietly disappears.
do $do$
declare
  v_def   text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer,integer)'::regprocedure);

  -- Each branch is replaced whole, between the line that opens it and the last line of the makes
  -- query that closes it. Every marker below occurs exactly once in the function, in both the
  -- shape 20260916120042 left behind and the one before it.
  v_cat_head text := '  if p_kind = ''catalog'' then';
  v_cat_tail text := 'from qvm_new_apps.parts_catalog where clean_make is not null;';
  v_agy_head text := '  elsif p_kind = ''agency'' then';
  v_agy_tail text := 'from qvm_new_apps.agency_price_reference where brand is not null;';
  v_stk_head text := '  elsif p_kind = ''stock'' then';
  v_stk_tail text := 'where brand is not null and (v_team or vendor_id = v_vendor);';
  v_pur_head text := '  elsif p_kind = ''purchases'' then';
  v_pur_tail text := 'from qvm_new_apps.part_purchase_history where brand is not null;';

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- CATALOGUE — unchanged, except that a part now carries what every holder says about it
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  v_cat text := $cat$  if p_kind = 'catalog' then
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
                                'branch', vb.branch_name,
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
                        where a.clean_part_number = c.clean_part_number
                       union all
                       select jsonb_build_object(
                                'id', 'stock-'||i.id, 'source', 'stock',
                                'holder', v.vendor_name, 'branch', vb.branch_name, 'city', vb.city,
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
      from qvm_new_apps.parts_catalog where clean_make is not null;$cat$;

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- AGENCY — one row per part, one child per vendor stating a price for it
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  v_agy text := $agy$  elsif p_kind = 'agency' then
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
                     'vendor', v.vendor_name, 'branch', vb.branch_name,
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
             where (v_q is null or a.clean_part_number ilike '%'||v_q||'%'
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
      from qvm_new_apps.agency_price_reference where brand is not null;$agy$;

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- STOCK — one row per part, one child per branch holding it
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  v_stk text := $stk$  elsif p_kind = 'stock' then
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
     where brand is not null and (v_team or vendor_id = v_vendor);$stk$;

  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  -- PAST PURCHASES — as 20260916120042 left it, with the catalogue join made lateral
  -- ═══════════════════════════════════════════════════════════════════════════════════════════
  v_pur text := $pur$  elsif p_kind = 'purchases' then
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
      from qvm_new_apps.part_purchase_history where brand is not null;$pur$;

  v_start integer;
  v_end   integer;
begin
  -- Each patch searches the text the previous one produced, so a marker that has already been
  -- consumed cannot be matched twice, and a branch that is not where this expects it raises here
  -- rather than leaving a half-rewritten function behind.
  v_start := position(v_cat_head in v_def);
  v_end   := position(v_cat_tail in v_def);
  if v_start = 0 or v_end = 0 or v_end < v_start then
    raise exception 'uploaded_records_get: the catalog branch is not where this migration expects '
                    'it (head %, tail %)', v_start, v_end;
  end if;
  v_def := left(v_def, v_start - 1) || v_cat || substr(v_def, v_end + length(v_cat_tail));

  v_start := position(v_agy_head in v_def);
  v_end   := position(v_agy_tail in v_def);
  if v_start = 0 or v_end = 0 or v_end < v_start then
    raise exception 'uploaded_records_get: the agency branch is not where this migration expects '
                    'it (head %, tail %)', v_start, v_end;
  end if;
  v_def := left(v_def, v_start - 1) || v_agy || substr(v_def, v_end + length(v_agy_tail));

  v_start := position(v_stk_head in v_def);
  v_end   := position(v_stk_tail in v_def);
  if v_start = 0 or v_end = 0 or v_end < v_start then
    raise exception 'uploaded_records_get: the stock branch is not where this migration expects '
                    'it (head %, tail %)', v_start, v_end;
  end if;
  v_def := left(v_def, v_start - 1) || v_stk || substr(v_def, v_end + length(v_stk_tail));

  v_start := position(v_pur_head in v_def);
  v_end   := position(v_pur_tail in v_def);
  if v_start = 0 or v_end = 0 or v_end < v_start then
    raise exception 'uploaded_records_get: the purchases branch is not where this migration '
                    'expects it (head %, tail %)', v_start, v_end;
  end if;
  v_def := left(v_def, v_start - 1) || v_pur || substr(v_def, v_end + length(v_pur_tail));

  execute v_def;
end
$do$;
