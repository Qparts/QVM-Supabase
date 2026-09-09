-- «1 records» over a table of four.
--
-- Every tab of the uploaded-records browser reported a total of exactly 1, whatever it was
-- showing — four agency rows said 1, an empty catalogue also said 1. The row count under the
-- search box has been wrong on every tab since the function was written.
--
-- The cause is one line, repeated five times:
--
--   select coalesce(jsonb_agg(x order by …), '[]'), count(*) over ()
--     into v_rows, v_total
--     from ( … limit … offset … ) s
--
-- jsonb_agg collapses the subquery to a single row, and only then does the window function run —
-- so `count(*) over ()` counts the one aggregated row it is standing on. It was never counting
-- records. It is the kind of mistake that reads correctly and cannot be right.
--
-- Moving the window inside the subquery fixes it, because window functions are evaluated before
-- LIMIT: `count(*) over ()` there sees the whole filtered set, not the page. The outer query then
-- just carries the number out with max().
--
-- Worth saying what else this was breaking. RecordsBrowser pages on this total, so with it pinned
-- at 1 the Next button was disabled on every tab — a file of ten thousand purchases showed its
-- first hundred rows and offered no way to reach the rest. The visible symptom was a wrong label;
-- the real one was that the other 9,900 rows were unreachable.
do $patch$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.uploaded_records_get(text,text,text,integer,integer)'::regprocedure);
  v_new text;
  v_hits integer;
begin
  -- The ordering key differs per tab — part_number for four of them, cost_on desc for purchases —
  -- so it is captured and carried through rather than spelled out five times.
  v_new := regexp_replace(
    v_def,
    E'coalesce\\(jsonb_agg\\(x order by ([^)]+)\\), ''\\[\\]''::jsonb\\), count\\(\\*\\) over \\(\\)\n      into v_rows, v_total\n      from \\(\n        select jsonb_build_object\\(',
    E'coalesce(jsonb_agg(x order by \\1), ''[]''::jsonb), coalesce(max(n), 0)\n      into v_rows, v_total\n      from (\n        select count(*) over () as n, jsonb_build_object(',
    'g');

  select count(*) into v_hits
    from regexp_matches(v_new, 'coalesce\(max\(n\), 0\)', 'g');
  if v_hits <> 5 then
    raise exception 'uploaded_records_get: patched % of the 5 tabs — refusing a partial fix', v_hits;
  end if;

  execute v_new;
end
$patch$;
