-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


create or replace function qvm_new_apps.is_report_admin()
returns boolean language sql stable security definer set search_path to '' as $$
  select exists (
    select 1 from qvm_new_apps.user_data ud
    where ud.user_id = auth.uid() and ud.user_role = 172
  );
$$;

create or replace function qvm_new_apps.get_report_settings()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_grants jsonb;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;
  select coalesce(jsonb_agg(to_jsonb(gr) order by gr.grant_id), '[]'::jsonb) into v_grants
  from (
    select
      g.grant_id, g.name, g.role, g.scope, g.created_at,
      coalesce((select jsonb_agg(jsonb_build_object('user_id', gu.user_id, 'user_name', ud.user_name, 'email', ud.email))
                from qvm_new_apps.report_permission_grant_users gu
                left join qvm_new_apps.user_data ud on ud.user_id = gu.user_id
                where gu.grant_id = g.grant_id), '[]'::jsonb) as users,
      coalesce((select jsonb_agg(jsonb_build_object('page_key', pa.page_key, 'can_view', pa.can_view, 'can_export', pa.can_export))
                from qvm_new_apps.report_permission_page_access pa
                where pa.grant_id = g.grant_id), '[]'::jsonb) as page_access,
      coalesce((select jsonb_agg(jsonb_build_object('page_key', sv.page_key, 'section_key', sv.section_key, 'is_visible', sv.is_visible))
                from qvm_new_apps.report_permission_section_visibility sv
                where sv.grant_id = g.grant_id), '[]'::jsonb) as section_visibility
    from qvm_new_apps.report_permission_grants g
  ) gr;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object('grants', v_grants));
end; $$;

create or replace function qvm_new_apps.get_report_assignable_users()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v jsonb;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', ud.user_id, 'user_name', ud.user_name, 'email', ud.email, 'role', rl.list_data
    ) order by ud.user_name), '[]'::jsonb) into v
  from qvm_new_apps.user_data ud
  left join qvm_new_apps.list_data rl on rl.list_data_id = ud.user_role
  where ud.user_id is not null and ud.user_type = 185;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v);
end; $$;

create or replace function qvm_new_apps.upsert_report_permission_grant(
  p_grant_id bigint, p_name text, p_role text, p_scope text,
  p_user_ids uuid[], p_pages jsonb, p_sections jsonb)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare v_id bigint;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;
  if p_name is null or btrim(p_name) = '' then
    return jsonb_build_object('status', false, 'message', 'Name is required', 'data', null);
  end if;
  if p_scope is null or p_scope not in ('own','team','all') then
    return jsonb_build_object('status', false, 'message', 'Invalid scope', 'data', null);
  end if;

  if p_grant_id is null then
    insert into qvm_new_apps.report_permission_grants(name, role, scope, created_by, updated_by)
    values (btrim(p_name), nullif(btrim(coalesce(p_role,'')),''), p_scope, auth.uid(), auth.uid())
    returning grant_id into v_id;
  else
    update qvm_new_apps.report_permission_grants
      set name = btrim(p_name), role = nullif(btrim(coalesce(p_role,'')),''),
          scope = p_scope, updated_by = auth.uid(), updated_at = now()
      where grant_id = p_grant_id
      returning grant_id into v_id;
    if v_id is null then
      return jsonb_build_object('status', false, 'message', 'Grant not found', 'data', null);
    end if;
  end if;

  delete from qvm_new_apps.report_permission_grant_users where grant_id = v_id;
  if p_user_ids is not null then
    insert into qvm_new_apps.report_permission_grant_users(grant_id, user_id)
    select v_id, u from unnest(p_user_ids) as u
    on conflict do nothing;
  end if;

  delete from qvm_new_apps.report_permission_page_access where grant_id = v_id;
  insert into qvm_new_apps.report_permission_page_access(grant_id, page_key, can_view, can_export)
  select v_id, x->>'page_key',
         coalesce((x->>'can_view')::boolean, false),
         coalesce((x->>'can_view')::boolean, false) and coalesce((x->>'can_export')::boolean, false)
  from jsonb_array_elements(coalesce(p_pages,'[]'::jsonb)) as x
  where (x->>'page_key') in ('overview','workshop','purchasing','partfinder','vendors')
    and coalesce((x->>'can_view')::boolean, false);

  delete from qvm_new_apps.report_permission_section_visibility where grant_id = v_id;
  insert into qvm_new_apps.report_permission_section_visibility(grant_id, page_key, section_key, is_visible)
  select v_id, x->>'page_key', x->>'section_key', coalesce((x->>'is_visible')::boolean, true)
  from jsonb_array_elements(coalesce(p_sections,'[]'::jsonb)) as x
  where (x->>'page_key') in ('overview','workshop','purchasing','partfinder','vendors');

  return jsonb_build_object('status', true, 'message', 'saved', 'data', jsonb_build_object('grant_id', v_id));
end; $$;

create or replace function qvm_new_apps.delete_report_permission_grant(p_grant_id bigint)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;
  delete from qvm_new_apps.report_permission_grants where grant_id = p_grant_id;
  return jsonb_build_object('status', true, 'message', 'deleted', 'data', null);
end; $$;

create or replace function qvm_new_apps.get_report_thresholds()
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v jsonb;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'key', key, 'label', label, 'value', value, 'value_unit', value_unit,
      'used_in_description', used_in_description, 'min_value', min_value,
      'max_value', max_value, 'updated_at', updated_at) order by label), '[]'::jsonb) into v
  from qvm_new_apps.report_settings_thresholds;
  return jsonb_build_object('status', true, 'message', 'ok', 'data', v);
end; $$;

create or replace function qvm_new_apps.update_report_threshold(p_key text, p_value numeric)
returns jsonb language plpgsql security definer set search_path to '' as $$
declare r qvm_new_apps.report_settings_thresholds;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;
  select * into r from qvm_new_apps.report_settings_thresholds where key = p_key;
  if not found then
    return jsonb_build_object('status', false, 'message', 'Unknown threshold', 'data', null);
  end if;
  if p_value is null then
    return jsonb_build_object('status', false, 'message', 'Value is required', 'data', null);
  end if;
  if r.min_value is not null and p_value < r.min_value then
    return jsonb_build_object('status', false, 'message', 'Value below the allowed minimum', 'data', null);
  end if;
  if r.max_value is not null and p_value > r.max_value then
    return jsonb_build_object('status', false, 'message', 'Value above the allowed maximum', 'data', null);
  end if;
  update qvm_new_apps.report_settings_thresholds
    set value = p_value, updated_by = auth.uid(), updated_at = now()
    where key = p_key;
  return jsonb_build_object('status', true, 'message', 'updated',
    'data', jsonb_build_object('key', p_key, 'value', p_value));
end; $$;

create or replace function qvm_new_apps.get_report_access_log(
  p_report_page text, p_action text, p_from timestamptz, p_to timestamptz,
  p_page int, p_page_size int)
returns jsonb language plpgsql stable security definer set search_path to '' as $$
declare v_rows jsonb; v_total bigint; v_size int; v_offset int;
begin
  if not qvm_new_apps.is_report_admin() then
    return jsonb_build_object('status', false, 'message', 'Not authorized', 'data', null);
  end if;
  v_size := greatest(coalesce(p_page_size, 50), 1);
  v_offset := greatest(coalesce(p_page, 1) - 1, 0) * v_size;

  select count(*) into v_total
  from qvm_new_apps.report_access_audit_log l
  where (p_report_page is null or l.report_page = p_report_page)
    and (p_action is null or l.action = p_action)
    and (p_from is null or l.created_at >= p_from)
    and (p_to   is null or l.created_at <= p_to);

  select coalesce(jsonb_agg(jsonb_build_object(
      'audit_id', l.audit_id, 'user_id', l.user_id, 'user_name', ud.user_name, 'email', ud.email,
      'report_page', l.report_page, 'action', l.action, 'scope_applied', l.scope_applied,
      'created_at', l.created_at) order by l.created_at desc), '[]'::jsonb) into v_rows
  from (
    select * from qvm_new_apps.report_access_audit_log l
    where (p_report_page is null or l.report_page = p_report_page)
      and (p_action is null or l.action = p_action)
      and (p_from is null or l.created_at >= p_from)
      and (p_to   is null or l.created_at <= p_to)
    order by l.created_at desc
    offset v_offset limit v_size
  ) l
  left join qvm_new_apps.user_data ud on ud.user_id = l.user_id;

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('rows', v_rows, 'total_count', v_total));
end; $$;

create or replace function qvm_new_apps.log_report_access(
  p_report_page text, p_action text, p_scope_applied text)
returns jsonb language plpgsql security definer set search_path to '' as $$
begin
  if auth.uid() is null then
    return jsonb_build_object('status', false, 'message', 'No session', 'data', null);
  end if;
  if p_action is null or p_action not in ('view','export') then
    return jsonb_build_object('status', false, 'message', 'Invalid action', 'data', null);
  end if;
  insert into qvm_new_apps.report_access_audit_log(user_id, report_page, action, scope_applied)
  values (auth.uid(), p_report_page, p_action, p_scope_applied);
  return jsonb_build_object('status', true, 'message', 'logged', 'data', null);
end; $$;

grant execute on function qvm_new_apps.is_report_admin() to authenticated;
grant execute on function qvm_new_apps.get_report_settings() to authenticated;
grant execute on function qvm_new_apps.get_report_assignable_users() to authenticated;
grant execute on function qvm_new_apps.upsert_report_permission_grant(bigint,text,text,text,uuid[],jsonb,jsonb) to authenticated;
grant execute on function qvm_new_apps.delete_report_permission_grant(bigint) to authenticated;
grant execute on function qvm_new_apps.get_report_thresholds() to authenticated;
grant execute on function qvm_new_apps.update_report_threshold(text,numeric) to authenticated;
grant execute on function qvm_new_apps.get_report_access_log(text,text,timestamptz,timestamptz,int,int) to authenticated;
grant execute on function qvm_new_apps.log_report_access(text,text,text) to authenticated;

notify pgrst, 'reload schema';
