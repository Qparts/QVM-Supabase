-- Past purchases, one row per part instead of one row per purchase line.
--
-- A purchase table is naturally one line per transaction, so a part bought eleven times reads as
-- eleven near-identical rows: the same number, the same name, the same make, eleven times over —
-- and the three fields that actually differ (who sold it, when, for how much) are pushed off the
-- right-hand edge by the ones that never do. Scrolling sideways to compare two prices of the same
-- part is the wrong shape for the question this table exists to answer.
--
-- So the part leads, and its lines sit under it. What is constant about a part — its number, its
-- approved name, its section, its make and class — is the row; what changes from one purchase to
-- the next is `children`, opened from the row. The summary the row carries (how many purchases,
-- how many units, the cost range) is the part of the detail worth seeing without opening anything.
--
-- `total` becomes the number of parts, which is what the page is now a list of. The tab-strip
-- counter is untouched and still counts purchase lines: it answers «how much is in this table»,
-- a different question from «how many parts am I looking at».
--
-- Patched rather than rewritten. uploaded_records_get carries five tabs and this changes one of
-- them; restating the whole body here is how the other four quietly lose a fix.
do $do$
declare
  v_def   text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer,integer)'::regprocedure);
  v_head  text := '  elsif p_kind = ''purchases'' then';
  v_tail  text := 'from qvm_new_apps.part_purchase_history where brand is not null;';
  v_start integer;
  v_end   integer;
  v_new   text := $patch$  elsif p_kind = 'purchases' then
    -- One row per part; every purchase of it travels with the row in `children`.
    select coalesce(jsonb_agg(x order by ord), '[]'::jsonb), coalesce(max(n), 0)
      into v_rows, v_total
      from (
        select g.n, g.clean_part_number as ord, jsonb_build_object(
                 -- The part number is the identity of a group — there is no single row id to give,
                 -- and the ids that exist belong to the lines underneath.
                 'id', g.clean_part_number,
                 'part_number', g.clean_part_number,
                 -- The catalogue's answer when it has one, the file's wording when it does not.
                 -- A part nobody has curated yet still has to say what it is.
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
          left join qvm_new_apps.parts_catalog pc
                 on pc.clean_part_number = g.clean_part_number) s;
    select coalesce(jsonb_agg(distinct brand), '[]'::jsonb) into v_makes
      from qvm_new_apps.part_purchase_history where brand is not null;$patch$;
begin
  v_start := position(v_head in v_def);
  v_end   := position(v_tail in v_def);
  -- A silent no-op here would leave the page reading a shape the server never started sending.
  if v_start = 0 or v_end = 0 or v_end < v_start then
    raise exception 'uploaded_records_get: the purchases branch is not where this migration '
                    'expects it (head %, tail %) — it was rewritten, and this patch would '
                    'corrupt the function', v_start, v_end;
  end if;
  v_def := left(v_def, v_start - 1) || v_new || substr(v_def, v_end + length(v_tail));
  execute v_def;
end
$do$;
