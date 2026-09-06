-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- A rule could be added and edited but never removed, so a mistake stayed on the list for
-- good. Rows already cleaned keep the numbers they were given — deleting the definition stops
-- it applying to the next file, it does not walk backwards through what it already did — which
-- is why a rule with rows behind it needs saying out loud before it goes.
create or replace function qvm_new_apps.upload_code_rule_delete(
  p_rule_id bigint, p_confirm boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_before jsonb;
  v_impact jsonb;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select to_jsonb(r) into v_before from qvm_new_apps.upload_code_rules r
   where r.rule_id = p_rule_id
     and (v_team or (r.source_kind = 'vendor' and r.source_id = v_vendor));
  if v_before is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  v_impact := qvm_new_apps.upload_code_rule_impact(p_rule_id);
  if not p_confirm and coalesce((v_impact->'data'->>'affected')::integer, 0) > 0 then
    return jsonb_build_object('status', false, 'message', 'needs_confirmation',
      'data', v_impact->'data');
  end if;

  delete from qvm_new_apps.upload_code_rules where rule_id = p_rule_id;

  insert into qvm_new_apps.upload_batch_log (action, detail, changed_by)
  values ('rule_delete', jsonb_build_object('rule_id', p_rule_id, 'before', v_before), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('rule_id', p_rule_id));
end
$function$;

revoke all on function qvm_new_apps.upload_code_rule_delete(bigint, boolean) from public;
grant execute on function qvm_new_apps.upload_code_rule_delete(bigint, boolean) to authenticated;
