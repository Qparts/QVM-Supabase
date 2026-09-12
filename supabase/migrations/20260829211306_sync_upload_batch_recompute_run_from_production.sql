-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

create or replace function qvm_new_apps.upload_batch_recompute_run(p_batch_id bigint, p_actor uuid)
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_b record; v_r record; v_c jsonb; v_seen text[] := '{}'; v_state text; v_kept integer := 0;
begin
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  for v_r in select * from qvm_new_apps.upload_rows
              where batch_id = p_batch_id order by row_number loop

    if v_r.edited_at is not null then
      -- Someone fixed this row by hand. Re-deriving it would throw their work away.
      v_kept := v_kept + 1;
      v_state := v_r.state;
      if v_state <> 'rejected' and v_r.clean_part_number = any(v_seen) then
        v_state := 'duplicate';
      elsif v_state <> 'rejected' and v_r.clean_part_number is not null then
        v_seen := v_seen || v_r.clean_part_number;
      end if;
      if v_state is distinct from v_r.state then
        update qvm_new_apps.upload_rows set
          state = v_state,
          reason = case when v_state = 'duplicate' then 'مكرر داخل نفس الملف' else reason end
        where row_id = v_r.row_id;
      end if;
      continue;
    end if;

    v_c := qvm_new_apps.upload_clean_row(v_r.raw, v_b.template_key, v_b.source_kind, v_b.source_id);
    v_state := v_c->>'state';
    if v_state <> 'rejected' and (v_c->>'clean_part_number') = any(v_seen) then
      v_state := 'duplicate';
    elsif v_state <> 'rejected' then
      v_seen := v_seen || (v_c->>'clean_part_number');
    end if;
    update qvm_new_apps.upload_rows set
      source_part_number = v_c->>'source_part_number',
      clean_part_number  = v_c->>'clean_part_number',
      display_part_number= v_c->>'display_part_number',
      clean_name         = v_c->>'clean_name',
      source_name_en     = v_c->>'source_name_en',
      clean_name_en      = v_c->>'clean_name_en',
      name_is_guess      = coalesce((v_c->>'name_is_guess')::boolean, false),
      matched_rule_id    = nullif(v_c->>'matched_rule_id','')::bigint,
      brand              = v_c->>'brand',
      part_class         = v_c->>'part_class',
      country_of_origin  = v_c->>'country_of_origin',
      state              = v_state,
      reason             = case when v_state = 'duplicate' then 'مكرر داخل نفس الملف'
                                else v_c->>'reason' end
    where row_id = v_r.row_id;
  end loop;

  update qvm_new_apps.upload_batches b set
    rows_ready     = (select count(*) from qvm_new_apps.upload_rows where batch_id = p_batch_id and state = 'ready'),
    rows_disabled  = (select count(*) from qvm_new_apps.upload_rows where batch_id = p_batch_id and state = 'disabled'),
    rows_rejected  = (select count(*) from qvm_new_apps.upload_rows where batch_id = p_batch_id and state = 'rejected'),
    rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = p_batch_id and state = 'duplicate'),
    updated_at     = now()
  where b.batch_id = p_batch_id;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, changed_by)
  values (p_batch_id, 'recompute', p_actor);

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(b) || jsonb_build_object('rows_kept_edited', v_kept)
               from qvm_new_apps.upload_batches b where b.batch_id = p_batch_id));
end $function$;

-- pg_cron has no auth.uid(), so the work lives here with EXECUTE revoked and the caller-facing
-- wrapper keeps the permission checks. Do not grant this.
revoke all on function qvm_new_apps.upload_batch_recompute_run(bigint, uuid) from public, anon, authenticated;
