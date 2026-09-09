-- Past purchases, each field twice: what the file said, and what the catalogue approved.
--
-- The agency table has read this way since 20260904192924, and the reason is the same here. A
-- single approved column is the one an admin cannot check — «why is this Aftermarket» meant
-- opening the supplier's own file beside the screen. Side by side, a bad reading is visible
-- without leaving the row, which is the whole point of keeping the raw value at all.
--
-- The names are the part that was actually missing. part_purchase_history has never stored the
-- name the supplier wrote — only the part number, the money and the dates — so «الوصف» from the
-- sheet was read during cleanup, used to fill the catalogue, and then dropped. Two of the twelve
-- columns being asked for could not be drawn from anything in the table. They are stored now.

-- ① The supplier's own words for the part, kept as they arrived.
alter table qvm_new_apps.part_purchase_history
  add column if not exists source_name    text,
  add column if not exists source_name_en text;

comment on column qvm_new_apps.part_purchase_history.source_name is
  'The name as the supplier''s file wrote it. Evidence, never corrected in place: the approved '
  'name lives in parts_catalog, where it is curated once per part rather than once per purchase.';

-- ② The writer keeps them. Without this the columns exist and stay empty for ever, which reads
-- exactly like a supplier who sent no names.
do $patch$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_batch_write_rows(bigint)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$      select r.row_number, r.source_part_number, r.clean_part_number, r.brand, r.part_class,
             r.raw, br.id as branch_id,$old$,
$new$      select r.row_number, r.source_part_number, r.clean_part_number, r.brand, r.part_class,
             r.source_name, r.source_name_en,
             r.raw, br.id as branch_id,$new$);
  if v_new = v_def then
    raise exception 'write_rows: the past_purchases source block was not found';
  end if;
  v_def := v_new;

  v_new := replace(v_def,
$old$      (source_part_number, clean_part_number, cost, retail_price, before_discount_price,
       cost_on, source_cost_date,
       supplier_name, vendor_id, city, qty, brand, brand_class, origin, client_branch_id, batch_id)
    select d.source_part_number, d.clean_part_number, d.v_cost,$old$,
$new$      (source_part_number, clean_part_number, source_name, source_name_en,
       cost, retail_price, before_discount_price,
       cost_on, source_cost_date,
       supplier_name, vendor_id, city, qty, brand, brand_class, origin, client_branch_id, batch_id)
    select d.source_part_number, d.clean_part_number, d.source_name, d.source_name_en, d.v_cost,$new$);
  if v_new = v_def then
    raise exception 'write_rows: the past_purchases insert was not found';
  end if;
  execute v_new;
end
$patch$;

-- ③ The reader joins the catalogue and the vendor, so the tab can show both halves.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$        select jsonb_build_object(
                 'id', h.id, 'part_number', h.clean_part_number, 'raw_part_number', h.source_part_number,
                 'make', h.brand, 'part_class', h.brand_class,
                 'supplier', h.supplier_name, 'cost', h.cost,$old$,
$new$        select jsonb_build_object(
                 'id', h.id, 'part_number', h.clean_part_number, 'raw_part_number', h.source_part_number,
                 -- The cleaned key is the approved number: it is what every other table joins on,
                 -- and what the catalogue row below was found by.
                 'official_part_number', h.clean_part_number,
                 'raw_name', h.source_name, 'raw_name_en', h.source_name_en,
                 'official_name_ar', pc.clean_name_ar, 'official_name_en', pc.clean_name_en,
                 'official_make', pc.clean_make,
                 'official_part_class', pc.clean_part_class,
                 'official_origin', pc.clean_country_manufacture,
                 -- The vendor this was resolved to, falling back to the text the file carried.
                 -- A purchase whose supplier was never matched still has to say who sold it.
                 'vendor', coalesce(v.vendor_name, h.supplier_name), 'city', h.city,
                 'make', h.brand, 'part_class', h.brand_class,
                 'supplier', h.supplier_name, 'cost', h.cost,$new$);
  if v_new = v_def then
    raise exception 'uploaded_records_get: the purchases row object was not found';
  end if;
  v_def := v_new;

  v_new := replace(v_def,
$old$          from qvm_new_apps.part_purchase_history h
         where (v_q is null or h.clean_part_number ilike '%'||v_q||'%'
                            or coalesce(h.supplier_name,'') ilike '%'||v_q||'%')$old$,
$new$          from qvm_new_apps.part_purchase_history h
          left join qvm_new_apps.parts_catalog pc on pc.clean_part_number = h.clean_part_number
          left join qvm_new_apps.vendors v on v.vendor_id = h.vendor_id
         where (v_q is null or h.clean_part_number ilike '%'||v_q||'%'
                            or h.source_part_number ilike '%'||v_q||'%'
                            or coalesce(h.source_name,'') ilike '%'||v_q||'%'
                            or coalesce(h.supplier_name,'') ilike '%'||v_q||'%')$new$);
  if v_new = v_def then
    raise exception 'uploaded_records_get: the purchases source was not found';
  end if;
  execute v_new;
end
$patch$;

-- ④ Purchases already written keep their staged row, so the name it arrived with can be put back
-- rather than left blank on every historic line. Matched on the batch and the part number, which
-- is the pair the writer itself used.
update qvm_new_apps.part_purchase_history h
   set source_name    = r.source_name,
       source_name_en = r.source_name_en
  from qvm_new_apps.upload_rows r
 where r.batch_id = h.batch_id
   and r.clean_part_number = h.clean_part_number
   and h.source_name is null
   and coalesce(r.source_name, r.source_name_en) is not null;
