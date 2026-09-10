-- «Why does the catalogue show parts that are not matched across the three tabs?»
--
-- Because right now not one of them is. Counted on this branch:
--
--   59 parts appear only in Past purchases
--    3 parts appear only in Agency list
--    1 part  appears only in Stock
--    0 parts appear in more than one
--
-- The three tabs hold unrelated data — the agency and stock rows are the one-row template files
-- from August, the 59 are the purchase sample loaded this week. Nothing overlaps, so every «seen
-- in» badge showing a single tab is the honest answer rather than a fault.
--
-- The catalogue itself stays the union, one row per real part. That is what makes it a catalogue:
-- every Official_* column on the other tabs reads it, and a part known from one file still has to
-- have somewhere to be known from. An intersection would empty it again — the exact state that
-- was just diagnosed as a bug — and would drop a real part the moment it arrived from one source.
--
-- What was missing is the question, not the answer. This adds it: show me only the parts seen in
-- more than one place. Today that returns nothing, and that is the finding.
--
-- The filter goes into the query rather than around it. Filtering the returned page instead would
-- take LIMIT 100, throw most of it away, and report the survivors as the total — so «2 records»
-- would mean «2 on this page», and page two would contradict page one.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer)'::regprocedure);
  v_new text;
begin
  -- ① the parameter
  v_new := replace(v_def,
    $old$p_limit integer DEFAULT 100, p_offset integer DEFAULT 0)$old$,
    $new$p_limit integer DEFAULT 100, p_offset integer DEFAULT 0, p_min_sources integer DEFAULT 0)$new$);
  if v_new = v_def then raise exception 'signature not found'; end if;
  v_def := v_new;

  -- ② somewhere to keep it
  v_new := replace(v_def,
    $old$  v_rows jsonb := '[]'::jsonb; v_total bigint := 0; v_makes jsonb := '[]'::jsonb;$old$,
    $new$  v_rows jsonb := '[]'::jsonb; v_total bigint := 0; v_makes jsonb := '[]'::jsonb;
  -- 0 or 1 = every part; 2 = only those seen in at least two of the three tabs.
  v_min integer := greatest(coalesce(p_min_sources, 0), 0);$new$);
  if v_new = v_def then raise exception 'declare block not found'; end if;
  v_def := v_new;

  -- ③ the condition, inside the catalogue branch's own WHERE so that limit, offset and total all
  -- agree with each other.
  v_new := replace(v_def,
$old$           and (v_make is null or c.clean_make = v_make)
         order by c.clean_part_number$old$,
$new$           and (v_make is null or c.clean_make = v_make)
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
         order by c.clean_part_number$new$);
  if v_new = v_def then raise exception 'catalogue where clause not found'; end if;

  execute v_new;
end
$patch$;

-- CREATE OR REPLACE with a longer argument list makes a second function, it does not replace the
-- first — and then a five-argument call matches both, because the sixth has a default. That is
-- exactly how is_qparts_admin took the WhatsApp inbox down. The old one goes.
drop function qvm_new_apps.uploaded_records_get(text, text, text, integer, integer);

revoke all on function qvm_new_apps.uploaded_records_get(text, text, text, integer, integer, integer) from public;
grant execute on function qvm_new_apps.uploaded_records_get(text, text, text, integer, integer, integer) to authenticated;

do $$
declare v_n integer;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'uploaded_records_get';
  if v_n <> 1 then
    raise exception 'uploaded_records_get has % overloads — a call cannot resolve', v_n;
  end if;
end
$$;
