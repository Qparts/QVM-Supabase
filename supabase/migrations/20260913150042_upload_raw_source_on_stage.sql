-- Keeping the file as the supplier wrote it, on every upload and not just the ones that existed
-- when the column came into being.
--
-- raw_source was added and backfilled, and upload_batch_stage was never taught to fill it. So
-- every new upload had it null, and the fallback `coalesce(raw_source, raw)` did what a fallback
-- does: it worked, silently, on the wrong thing.
--
-- The failure showed up one step later. Applying a column map rewrites `raw` into our canonical
-- keys. Reopening the panel then read those keys back as if they were the supplier's headers —
-- and since nothing named `city` or `purchase_date` was an alias for itself, they matched
-- nothing and were offered as «ignore this column». Applying again on that screen would have
-- dropped the very columns the first pass had just filled, and divided the price a second time.
--
-- Three holes, all from the one omission:
--   · staging never captured the pristine copy
--   · a canonical name was not an alias for itself
--   · apply trusted that the pristine copy already existed

do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_batch_stage(text,text,jsonb,text,bigint,text,text,bigint[])'::regprocedure);
  v_old text := '    insert into qvm_new_apps.upload_rows
      (batch_id, row_number, raw, source_part_number, clean_part_number,';
  v_new text := '    insert into qvm_new_apps.upload_rows
      -- raw_source is the file as the supplier wrote it and is never rewritten. Without it,
      -- applying a column map a second time reads our own canonical names back as if they were
      -- the file''s headers, offers to ignore them, and destroys the columns it just filled.
      (batch_id, row_number, raw, raw_source, source_part_number, clean_part_number,';
  v_old2 text := '    values (v_batch, v_n, v_row,';
  v_new2 text := '    values (v_batch, v_n, v_row, v_row,';
begin
  if position('raw_source' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then raise exception 'column list not matched'; end if;
  if position(v_old2 in v_def) = 0 then raise exception 'values list not matched'; end if;
  v_def := replace(v_def, v_old, v_new);
  v_def := replace(v_def, v_old2, v_new2);
  execute v_def;
end
$mig$;

-- A file that already uses our own names had no alias for them, so «city» matched nothing and
-- was offered as «ignore this column». Every template key is now an alias for itself.
insert into qvm_new_apps.upload_column_aliases (target_key, norm_alias, sample_alias)
select distinct c->>'key', qvm_new_apps.norm_text(c->>'key'), c->>'key'
  from qvm_new_apps.upload_templates t, lateral jsonb_array_elements(t.columns) c
 where c->>'key' is not null
on conflict (target_key, norm_alias) do nothing;

-- Rows staged before this keep their current contents as the pristine copy. For a batch already
-- mapped that is our canonical naming rather than the supplier's, which is not recoverable now —
-- but it is self-consistent, and the identity aliases above make it read correctly instead of
-- offering to discard itself.
update qvm_new_apps.upload_rows set raw_source = raw where raw_source is null;

-- And apply captures it too, before it rewrites anything, so no row staged by an older build can
-- reach the rewrite without a pristine copy behind it.
do $mig$
declare
  v_def text := pg_get_functiondef('qvm_new_apps.upload_batch_apply_columns(jsonb)'::regprocedure);
  v_old text := '  select e->>''header'' into v_qty_header from jsonb_array_elements(v_map) e';
  v_new text := '  -- Belt and braces for any row staged before raw_source existed: capture the pristine copy
  -- BEFORE anything is rewritten, so a second apply can never read our own output back as if it
  -- were the supplier''s headers and then offer to discard it.
  update qvm_new_apps.upload_rows
     set raw_source = raw
   where batch_id = v_batch and raw_source is null;

  select e->>''header'' into v_qty_header from jsonb_array_elements(v_map) e';
begin
  if position('Belt and braces' in v_def) > 0 then return; end if;
  if position(v_old in v_def) = 0 then raise exception 'anchor not matched'; end if;
  execute replace(v_def, v_old, v_new);
end
$mig$;
