-- The catalogue counts every cleaned part, not only the ones all three tabs happen to share.
--
-- The tab was defined as the intersection of agency, stock and past purchases, which answered
-- «which parts do we have a complete picture of» — a real question, but not the one the tab is
-- for. A part that was cleaned, named and classified is in the catalogue whether or not anyone
-- has priced it yet; hiding it until three separate files line up means the table cannot be used
-- to see what the cleanup has actually produced, and a part drops out of sight the moment one of
-- the three stops carrying it.
--
-- So the listing widens to every catalogue row, and «where was this seen» moves from being the
-- condition for appearing to being a fact shown on the row — the badges were already there, and
-- they now carry the information the filter used to throw rows away for.
--
-- Only the tab-strip counter is patched here: the listing itself is filtered by p_min_sources,
-- which the page passes, so the page alone decides how wide the tab is. The counter is computed
-- in this function and had the intersection hard-coded into it, which would have left the strip
-- reading 11 above a table of 66.
do $do$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer,integer)'::regprocedure);
  v_old text := $old$      'catalog',   case when v_team then (
                     select count(*) from qvm_new_apps.parts_catalog c
                      where exists (select 1 from qvm_new_apps.agency_price_reference x
                                     where x.clean_part_number = c.clean_part_number)
                        and exists (select 1 from qvm_new_apps.inventory_stock x
                                     where x.clean_part_number = c.clean_part_number)
                        and exists (select 1 from qvm_new_apps.part_purchase_history x
                                     where x.clean_part_number = c.clean_part_number)) else 0 end,$old$;
  v_new text := $new$      -- Every cleaned part. What the tab lists is decided by p_min_sources, and this has to
      -- agree with it or the strip contradicts the table underneath it.
      'catalog',   case when v_team then (select count(*) from qvm_new_apps.parts_catalog) else 0 end,$new$;
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  if v_hits <> 1 then
    raise exception 'uploaded_records_get: expected the catalogue counter exactly once, found % — '
                    'it was rewritten, and this patch would leave the strip disagreeing with the '
                    'table', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
