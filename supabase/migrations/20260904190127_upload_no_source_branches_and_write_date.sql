-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Three things the upload screen was asking for that it should not have to.
--
-- 1. Stock on hand has no supplier. It is what we hold, in our own branch, so «which source
--    is this file from» had no answer — the person uploading is the source.
--
-- 2. Past purchases carries its supplier per row, in the supplier_name column, because one
--    file covers purchases from many of them. Asking for a single source above the file
--    contradicted the sheet. The branch comes back instead: what matters is which of our
--    branches did the buying.
--
-- 3. «Effective from» was a date somebody typed before every price list — a hand-kept second
--    copy of the upload date that could only ever drift. It is stamped on write and
--    re-stamped on every replacement, which is what the «يسري من» column was read as anyway.

update qvm_new_apps.upload_templates set needs_vendor = false where template_key = 'stock_on_hand';
update qvm_new_apps.upload_templates set needs_vendor = false, needs_branch = true
 where template_key = 'past_purchases';

-- Purchases had nowhere to record a branch, so the answer would have been collected and
-- dropped. Same column name as the other two destinations.
alter table qvm_new_apps.part_purchase_history
  add column if not exists client_branch_id integer;

do $$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'upload_batch_write_rows';
  if v_def is null then raise exception 'upload_batch_write_rows not found'; end if;

  -- (3) the agency price is in force from the day it landed
  v_def := replace(v_def,
    E'           coalesce(nullif(r.raw->>''effective_from'','''')::date, v_eff),',
    E'           current_date,   -- in force from the day it landed, re-stamped on replacement');
  if position('current_date,   -- in force' in v_def) = 0 then
    raise exception 'effective_from was not switched to the write date';
  end if;

  -- (2) purchases record the branch that did the buying
  v_def := replace(v_def,
    E'       supplier_name, city, qty, brand, brand_class, origin, batch_id)',
    E'       supplier_name, city, qty, brand, brand_class, origin, client_branch_id, batch_id)');
  v_def := replace(v_def,
    E'           r.brand, r.part_class, ''external_excel'', v_b.batch_id\n'
    || E'      from qvm_new_apps.upload_rows r\n'
    || E'     where r.batch_id = p_batch_id and r.state = ''ready''',
    E'           r.brand, r.part_class, ''external_excel'', br.id, v_b.batch_id\n'
    || E'      from qvm_new_apps.upload_rows r\n'
    || E'      cross join unnest(v_branches) as br(id)\n'
    || E'     where r.batch_id = p_batch_id and r.state = ''ready''');
  v_def := replace(v_def,
    E'          where h.clean_part_number = r.clean_part_number',
    E'          where h.clean_part_number = r.clean_part_number\n'
    || E'            and h.client_branch_id is not distinct from br.id');

  if position('origin, client_branch_id, batch_id)' in v_def) = 0
     or position('cross join unnest(v_branches) as br(id)' in v_def) = 0
     or position('h.client_branch_id is not distinct from br.id' in v_def) = 0 then
    raise exception 'the purchases branch rewrite did not take';
  end if;

  execute v_def;
end $$;
