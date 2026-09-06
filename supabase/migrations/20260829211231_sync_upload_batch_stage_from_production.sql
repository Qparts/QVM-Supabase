-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

create or replace function qvm_new_apps.upload_batch_stage(
  p_template_key text, p_file_name text, p_rows jsonb,
  p_source_kind text default 'vendor', p_source_id bigint default null,
  p_source_label text default null, p_branch_scope text default 'all',
  p_branch_ids bigint[] default '{}'::bigint[])
returns jsonb language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_batch bigint; v_row jsonb; v_clean jsonb; v_n integer := 0;
  v_seen text[] := '{}'; v_state text;
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_kind text := p_source_kind; v_sid bigint := p_source_id; v_label text := p_source_label;
  v_ids bigint[] := coalesce(p_branch_ids, '{}');
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  if not exists (select 1 from qvm_new_apps.upload_templates
                  where template_key = p_template_key and is_active
                    and (v_team or allowed_for_vendor)) then
    return jsonb_build_object('status', false,
      'message', case when v_team then 'نوع ملف غير معروف'
                      else 'هذا النوع من الملفات لا يرفعه المورد' end, 'data', null);
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('status', false, 'message', 'الملف لا يحتوي على صفوف', 'data', null);
  end if;

  -- A vendor writes as themselves whatever the request said. Trusting the
  -- caller here would let one supplier file stock under another's name, and
  -- the code rules are keyed on that name.
  if not v_team then
    v_kind := 'vendor';
    v_sid := v_vendor;
    select vendor_name into v_label from qvm_new_apps.vendors where vendor_id = v_vendor;
    -- Same for branches: only their own, and silently dropping someone else's
    -- id is safer than failing on it.
    v_ids := coalesce((select array_agg(b.vendor_branch_id)
                         from qvm_new_apps.vendor_branches b
                        where b.vendor_id = v_vendor and b.vendor_branch_id = any(v_ids)), '{}');
    if p_branch_scope = 'specific' and array_length(v_ids, 1) is null then
      return jsonb_build_object('status', false,
        'message', 'لم تُختَر فروع تخصّك', 'data', null);
    end if;
  end if;

  insert into qvm_new_apps.upload_batches
    (template_key, file_name, source_kind, source_id, source_label,
     branch_scope, branch_ids, status, uploaded_by)
  values (p_template_key, p_file_name, v_kind, v_sid, v_label,
          p_branch_scope, v_ids, 'preview', auth.uid())
  returning batch_id into v_batch;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_n := v_n + 1;
    v_clean := qvm_new_apps.upload_clean_row(v_row, p_template_key, v_kind, v_sid);
    v_state := v_clean->>'state';
    if v_state <> 'rejected' and (v_clean->>'clean_part_number') = any(v_seen) then
      v_state := 'duplicate';
    elsif v_state <> 'rejected' then
      v_seen := v_seen || (v_clean->>'clean_part_number');
    end if;

    insert into qvm_new_apps.upload_rows
      (batch_id, row_number, raw, source_part_number, clean_part_number,
       display_part_number, source_name, clean_name, source_name_en, clean_name_en, name_is_guess,
       matched_rule_id, brand,
       part_class, country_of_origin, state, reason)
    values (v_batch, v_n, v_row,
            v_clean->>'source_part_number', v_clean->>'clean_part_number',
            v_clean->>'display_part_number',
            v_clean->>'source_name', v_clean->>'clean_name',
            v_clean->>'source_name_en', v_clean->>'clean_name_en',
            coalesce((v_clean->>'name_is_guess')::boolean, false),
            nullif(v_clean->>'matched_rule_id', '')::bigint,
            v_clean->>'brand', v_clean->>'part_class', v_clean->>'country_of_origin',
            v_state,
            case when v_state = 'duplicate' then 'مكرر داخل نفس الملف'
                 else v_clean->>'reason' end);
  end loop;

  update qvm_new_apps.upload_batches b set
    rows_total     = v_n,
    rows_ready     = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'ready'),
    rows_disabled  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'disabled'),
    rows_rejected  = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'rejected'),
    rows_duplicate = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'duplicate'),
    updated_at     = now()
  where b.batch_id = v_batch;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (v_batch, 'stage', jsonb_build_object('file', p_file_name, 'rows', v_n), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(b) from qvm_new_apps.upload_batches b where b.batch_id = v_batch));
end
$function$;
