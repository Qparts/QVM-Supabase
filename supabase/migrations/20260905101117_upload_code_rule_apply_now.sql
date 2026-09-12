-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- «19 غير مرتبط» was a number you could read and not act on.
--
-- Those rows are waiting on a definition that now exists: a rule written after a file was
-- imported does not reach backwards on its own, so the rows sat disabled while the rule that
-- explains them sat one line above. This runs the same cleaning pass over that source's files
-- that a fresh upload would get, and reports how many rows it actually moved.
--
-- It reports rather than promises: `unlinked` counts every disabled row from the source, not
-- the ones this rule's code matches, so telling somebody nineteen will link when four will is
-- a lie the screen would be caught in a second later.
create or replace function qvm_new_apps.upload_code_rule_apply(
  p_rule_id bigint, p_include_published boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_rule record;
  v_b bigint;
  v_batches integer := 0;
  v_before integer;
  v_after integer;
  v_linked integer;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select * into v_rule from qvm_new_apps.upload_code_rules r
   where r.rule_id = p_rule_id
     and (v_team or (r.source_kind = 'vendor' and r.source_id = v_vendor));
  if v_rule is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;

  select count(*) into v_before
    from qvm_new_apps.upload_rows u
    join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
   where b.source_kind = v_rule.source_kind
     and coalesce(b.source_id, -1) = coalesce(v_rule.source_id, -1)
     and u.state = 'disabled';

  for v_b in
    select b.batch_id from qvm_new_apps.upload_batches b
     where b.source_kind = v_rule.source_kind
       and coalesce(b.source_id, -1) = coalesce(v_rule.source_id, -1)
       and (b.status <> 'published' or p_include_published)
  loop
    if (select status from qvm_new_apps.upload_batches where batch_id = v_b) = 'published' then
      -- Published rows are already live, so this rewrites them from the rules as they now
      -- stand. That is the whole request when somebody presses the count on a live file.
      perform qvm_new_apps.upload_batch_reprocess(v_b);
    else
      perform qvm_new_apps.upload_batch_recompute(v_b);
    end if;
    v_batches := v_batches + 1;
  end loop;

  select count(*) into v_after
    from qvm_new_apps.upload_rows u
    join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
   where b.source_kind = v_rule.source_kind
     and coalesce(b.source_id, -1) = coalesce(v_rule.source_id, -1)
     and u.state = 'disabled';

  select count(*) into v_linked
    from qvm_new_apps.upload_rows u where u.matched_rule_id = p_rule_id;

  insert into qvm_new_apps.upload_batch_log (action, detail, changed_by)
  values ('rule_apply',
          jsonb_build_object('rule_id', p_rule_id, 'batches', v_batches,
                             'disabled_before', v_before, 'disabled_after', v_after),
          auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'batches', v_batches,
    'resolved', greatest(v_before - v_after, 0),
    'still_unlinked', v_after,
    'linked', v_linked));
end
$function$;

revoke all on function qvm_new_apps.upload_code_rule_apply(bigint, boolean) from public;
grant execute on function qvm_new_apps.upload_code_rule_apply(bigint, boolean) to authenticated;
