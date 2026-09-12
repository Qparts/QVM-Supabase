-- part_purchase_history.origin is not a country of manufacture.
--
-- It holds the literal 'external_excel' on every row — a marker for how the row arrived. The
-- catalogue backfill in 20260913250042 passed it through as the country, so 59 parts came out
-- claiming to be manufactured in «external_excel». None of them reached is_complete, because they
-- are also missing a make, a class and a name, so nothing leaked into pricing. But it reads as a
-- real answer on screen, and the moment one of those parts learned its make and class it would
-- have counted as complete on the strength of a word that means nothing.
--
-- The live path was never wrong: upload_batch_write_rows absorbs country_of_origin from the
-- staged row, not from this column. Only the backfill was, and 20260913250042 now passes null —
-- so this repairs the rows that one pass already wrote, and a fresh replay never writes them.
update qvm_new_apps.parts_catalog
   set clean_country_manufacture = null, updated_at = now()
 where clean_country_manufacture = 'external_excel';

do $$
declare v_left integer;
begin
  select count(*) into v_left from qvm_new_apps.parts_catalog
   where clean_country_manufacture = 'external_excel';
  if v_left <> 0 then
    raise exception '% parts still claim external_excel as a country', v_left;
  end if;
end
$$;
