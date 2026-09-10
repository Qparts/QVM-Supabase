-- «Past purchases 0», directly above a card reading «59 accepted rows».
--
-- Both numbers are right and they cannot both be read. The tab chip counts records in force, and
-- with the file still in preview there are none; the card counts what the file produced, and it
-- produced 59. Somebody looking at the two together does not learn that saving is outstanding —
-- they learn that one of the numbers on this screen is broken, and then they stop trusting the
-- other one too.
--
-- The chip is not going to start counting unsaved rows: it is the count of what is live, it is
-- what makes the tab strip a map of the system, and a tab that inflates itself with rows nobody
-- has approved is worse than a tab reading zero. What was missing is the second number. This
-- returns it — per file type, so every chip can say it at once rather than only the tab that
-- happens to be open.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_data_get(text,text,text,integer,integer)'::regprocedure);
  v_new text;
begin
  v_new := replace(v_def,
$old$    'counters', (select jsonb_build_object($old$,
$new$    -- Rows analysed and not yet saved, keyed by file type. Deliberately not filtered by
    -- p_template_key: the tab strip draws every type at once, and a map that only knows about
    -- the tab you are standing on is not a map.
    'pending_rows', coalesce((
      select jsonb_object_agg(p.template_key, p.n)
        from (select b.template_key, sum(b.rows_ready) as n
                from qvm_new_apps.upload_batches b
               where b.status = 'preview' and b.rows_ready > 0
                 and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))
               group by b.template_key) p), '{}'::jsonb),

    'counters', (select jsonb_build_object($new$);
  if v_new = v_def then
    raise exception 'uploaded_data_get: the counters key was not found';
  end if;
  execute v_new;
end
$patch$;
