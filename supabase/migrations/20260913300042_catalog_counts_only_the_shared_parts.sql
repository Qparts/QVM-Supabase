-- The catalogue tab now shows only the parts present in all three tabs, so its chip has to count
-- the same thing. Left alone it would read 64 above a table showing 0 — the same contradiction as
-- «Past purchases 0» over «59 accepted rows», and the same lesson: two numbers on one screen that
-- cannot both be true teach somebody that neither can be trusted.
--
-- parts_catalog itself is untouched and still holds every part. The Official_* columns on the
-- other tabs join the table directly, not through this reader, so narrowing what the tab lists
-- does not take the approved name and class away from Agency, Stock or Past purchases.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer,integer)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$      'catalog',   case when v_team then (select count(*) from qvm_new_apps.parts_catalog) else 0 end,$old$,
$new$      'catalog',   case when v_team then (
                     select count(*) from qvm_new_apps.parts_catalog c
                      where exists (select 1 from qvm_new_apps.agency_price_reference x
                                     where x.clean_part_number = c.clean_part_number)
                        and exists (select 1 from qvm_new_apps.inventory_stock x
                                     where x.clean_part_number = c.clean_part_number)
                        and exists (select 1 from qvm_new_apps.part_purchase_history x
                                     where x.clean_part_number = c.clean_part_number)) else 0 end,$new$);
  if v_new = v_def then
    raise exception 'uploaded_records_get: the catalogue count was not found';
  end if;
  execute v_new;
end
$patch$;
