-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

create or replace function qvm_new_apps.upload_batch_get(
  p_batch_id bigint, p_state text default null, p_limit integer default 200, p_offset integer default 0)
returns jsonb language plpgsql stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
begin
  if not qvm_new_apps.may_touch_upload_batch(p_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'batch', (select to_jsonb(b) from qvm_new_apps.upload_batches b where b.batch_id = p_batch_id),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
               'row_id', r.row_id, 'row_number', r.row_number,
               'source_part_number', r.source_part_number,
               'display_part_number', r.display_part_number,
               'clean_part_number', r.clean_part_number,
               'source_name', r.source_name, 'clean_name', r.clean_name,
               'source_name_en', r.source_name_en, 'clean_name_en', r.clean_name_en,
               -- Whether the name was read from the sheet or worked out from a similar part
               -- number. Without it the preview cannot tell «مُملّى تلقائيًا» from «اسم مقترح»,
               -- and the badge that warns about a guess could never appear at all.
               'name_is_guess', r.name_is_guess,
               -- Set once a person corrected the row by hand; a recompute then leaves it alone.
               'edited_at', r.edited_at,
               'brand', r.brand, 'part_class', r.part_class,
               'country_of_origin', r.country_of_origin,
               'matched_rule', (select rr.code || ' (' || rr.position || ')'
                                  from qvm_new_apps.upload_code_rules rr
                                 where rr.rule_id = r.matched_rule_id),
               'state', r.state, 'reason', r.reason, 'raw', r.raw)
             order by r.row_number)
        from (select * from qvm_new_apps.upload_rows
               where batch_id = p_batch_id and (p_state is null or state = p_state)
               order by row_number limit p_limit offset p_offset) r), '[]'::jsonb),
    'shown', (select count(*) from qvm_new_apps.upload_rows
               where batch_id = p_batch_id and (p_state is null or state = p_state))
  ));
end
$function$;

create or replace function qvm_new_apps.upload_row_update(p_row_id bigint, p_patch jsonb)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_row record;
  v_clean text;
  v_state text;
begin
  select r.*, b.batch_id as b_batch_id into v_row
    from qvm_new_apps.upload_rows r
    join qvm_new_apps.upload_batches b on b.batch_id = r.batch_id
   where r.row_id = p_row_id;

  if v_row.row_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  if not qvm_new_apps.may_touch_upload_batch(v_row.b_batch_id) then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- Presence semantics, not COALESCE: a key that is present and null means "clear this", which is
  -- the only way to remove a wrong brand or country. A key that is absent means "leave it".
  v_clean := case when p_patch ? 'clean_part_number'
                  then qvm_new_apps.normalize_part_number(nullif(btrim(p_patch->>'clean_part_number'), ''))
                  else v_row.clean_part_number end;

  -- The clean part number is the key every live table is written against; a row without one has
  -- nothing to attach to, so it is refused rather than saved into a broken state.
  if v_clean is null then
    return jsonb_build_object('status', false,
      'message', 'رقم القطعة النظيف مطلوب — لا يمكن حفظ صف بدونه', 'data', null);
  end if;

  v_state := case when p_patch ? 'state' then p_patch->>'state' else v_row.state end;
  if v_state not in ('ready', 'disabled', 'rejected', 'duplicate') then
    return jsonb_build_object('status', false, 'message', 'حالة غير معروفة: ' || v_state, 'data', null);
  end if;

  update qvm_new_apps.upload_rows r set
    clean_part_number   = v_clean,
    display_part_number = case when p_patch ? 'display_part_number'
                               then nullif(btrim(p_patch->>'display_part_number'), '')
                               else r.display_part_number end,
    clean_name          = case when p_patch ? 'clean_name'
                               then nullif(btrim(p_patch->>'clean_name'), '') else r.clean_name end,
    clean_name_en       = case when p_patch ? 'clean_name_en'
                               then nullif(btrim(p_patch->>'clean_name_en'), '') else r.clean_name_en end,
    -- A name a person typed is not a guess, whatever the ladder had decided before.
    name_is_guess       = case when p_patch ? 'clean_name' then false else r.name_is_guess end,
    brand               = case when p_patch ? 'brand'
                               then nullif(btrim(p_patch->>'brand'), '') else r.brand end,
    part_class          = case when p_patch ? 'part_class'
                               then nullif(btrim(p_patch->>'part_class'), '') else r.part_class end,
    country_of_origin   = case when p_patch ? 'country_of_origin'
                               then nullif(btrim(p_patch->>'country_of_origin'), '') else r.country_of_origin end,
    state               = v_state,
    -- The reason describes what the cleanup wanted fixed. Once a person has fixed it, leaving the
    -- old complaint on screen next to a good row is just noise.
    reason              = case when v_state = 'ready' then null else r.reason end,
    edited_at           = now(),
    edited_by           = auth.uid()
  where r.row_id = p_row_id;

  update qvm_new_apps.upload_batches b set
    rows_ready     = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_row.b_batch_id and state = 'ready'),
    rows_disabled  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_row.b_batch_id and state = 'disabled'),
    rows_rejected  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_row.b_batch_id and state = 'rejected'),
    rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_row.b_batch_id and state = 'duplicate'),
    updated_at     = now()
  where b.batch_id = v_row.b_batch_id;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, changed_by)
  values (v_row.b_batch_id, 'row_edit', auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(r) from qvm_new_apps.upload_rows r where r.row_id = p_row_id));
end
$function$;
