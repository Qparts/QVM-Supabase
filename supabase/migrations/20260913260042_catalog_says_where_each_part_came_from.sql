-- The catalogue index is one row per real part, gathered from the three tabs above it. It has
-- never said which of them a part came from — so «where did this part number come from» meant
-- opening Agency, then Stock, then Past purchases and searching each one.
--
-- Computed at read time rather than stored. A part's sources change whenever a file is published
-- or a batch is rolled back, and a stored column would have to be invalidated by every one of
-- those paths; the truth is three index lookups away and cannot go stale.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$                 'missing', array_to_json(array_remove(array[
                     case when c.clean_part_class is null then 'الصنف' end,$old$,
$new$                 -- Which of the three tabs holds this number. Ordered, so the badges do not
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
                 'missing', array_to_json(array_remove(array[
                     -- The make counts as missing now that a part may be held without one. It is
                     -- the first term of the generated is_complete, so leaving it out of this
                     -- list would print «ينقصها: —» beside a row the system calls incomplete.
                     case when c.clean_make is null then 'الماركة' end,
                     case when c.clean_part_class is null then 'الصنف' end,$new$);
  if v_new = v_def then
    raise exception 'uploaded_records_get: the catalogue row object was not found';
  end if;
  execute v_new;
end
$patch$;
