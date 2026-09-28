-- A company admin uploads for the company's own vendors.
--
-- On the agency list, stock and past purchases uploads the vendor picker, the «attach a vendor»
-- picker on a file and the manual add-record form list only the vendors linked to the admin's
-- company (vendor_companies), and the stage and set-source paths refuse any other vendor. The
-- Qparts admin, and Qparts team members who are not a company's admin, still see every vendor.

set search_path to qvm_new_apps, public;

create or replace function qvm_new_apps.upload_vendor_visible(p_vendor_id integer)
 returns boolean
 language sql
 stable security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
  select qvm_new_apps.is_qparts_admin(auth.uid())
      or not qvm_new_apps.is_company_admin(auth.uid())
      or exists (select 1 from qvm_new_apps.vendor_companies vc
                  where vc.vendor_id = p_vendor_id
                    and vc.company_id in (select company_id from qvm_new_apps.permission_companies(auth.uid())));
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_page_get()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_scope integer[] := qvm_new_apps.get_internal_branch_scope(auth.uid());
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(

    'is_vendor', not v_team,
    'vendor_id', v_vendor,

    'templates', coalesce((
      select jsonb_agg(to_jsonb(t) order by t.sort_order)
        from qvm_new_apps.upload_templates t
       where t.is_active and (v_team or t.allowed_for_vendor)), '[]'::jsonb),

    'rules', coalesce((
      select jsonb_agg(jsonb_build_object(
               'rule_id', r.rule_id, 'source_kind', r.source_kind,
               'source_id', r.source_id, 'source_label', r.source_label,
               'code', r.code, 'position', r.position, 'treatment', r.treatment,
               'brand', r.brand, 'part_class', r.part_class,
               'record_kind', r.record_kind,
               'country_of_origin', r.country_of_origin, 'created_at', r.created_at,
               'linked', (select count(*) from qvm_new_apps.upload_rows u
                           where u.matched_rule_id = r.rule_id),
               'unlinked', (select count(*) from qvm_new_apps.upload_rows u
                             join qvm_new_apps.upload_batches b on b.batch_id = u.batch_id
                            where b.source_kind = r.source_kind
                              and coalesce(b.source_id, -1) = coalesce(r.source_id, -1)
                              and u.state = 'disabled'))
             order by r.source_label, r.code)
        from qvm_new_apps.upload_code_rules r
       where v_team or (r.source_kind = 'vendor' and r.source_id = v_vendor)), '[]'::jsonb),

    'batches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'batch_id', b.batch_id, 'template_key', b.template_key,
               'file_name', b.file_name, 'status', b.status,
               'source_label', b.source_label, 'branch_scope', b.branch_scope,
               'branches', qvm_new_apps.upload_batch_branches_json(b.batch_id),
               'rows_total', b.rows_total, 'rows_ready', b.rows_ready,
               'rows_disabled', b.rows_disabled, 'rows_rejected', b.rows_rejected,
               'rows_duplicate', b.rows_duplicate, 'rows_held', b.rows_held,
               'uploaded_by_name', u.user_name,
               'created_at', b.created_at, 'published_at', b.published_at)
             order by b.created_at desc)
        from (select * from qvm_new_apps.upload_batches
               where qvm_new_apps.is_qparts_team()
                  or (source_kind = 'vendor' and source_id = qvm_new_apps.current_upload_vendor_id())
               order by created_at desc limit 50) b
        left join qvm_new_apps.user_data u on u.user_id = b.uploaded_by), '[]'::jsonb),

    'totals', (select jsonb_build_object(
                 'accepted', coalesce(sum(rows_ready), 0),
                 'failed', coalesce(sum(rows_rejected), 0))
                 from qvm_new_apps.upload_batches b
                where v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor)),

    'options', jsonb_build_object(
      -- A vendor picks nothing: they are the source, and their own branches
      -- are the only ones on offer.
      'vendors', coalesce((select jsonb_agg(jsonb_build_object('id', v.vendor_id, 'name', v.vendor_name)
                                   order by v.vendor_name)
                             from qvm_new_apps.vendors v
                            where (v_team or v.vendor_id = v_vendor)
                              and qvm_new_apps.upload_vendor_visible(v.vendor_id)), '[]'::jsonb),
      'client_branches', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', cb.customer_id, 'name', cb.branch_name,
                             'city', cb.city, 'company', ld.list_data)
                           order by cb.branch_name)
                             from qvm_new_apps.client_branches cb
                             left join qvm_new_apps.list_data ld on ld.list_data_id = cb.list_data_id
                            where coalesce(btrim(cb.branch_name), '''') <> ''''
                              and (v_scope is null or cb.customer_id = any(v_scope))), '[]'::jsonb),
      'vendor_branches', coalesce((select jsonb_agg(jsonb_build_object(
                             'id', vb.vendor_branch_id, 'vendor_id', vb.vendor_id,
                             'name', coalesce(vb.branch_name, ''), 'city', vb.city)
                           order by vb.branch_name)
                             from qvm_new_apps.vendor_branches vb
                            where coalesce(vb.is_active, true)
                              and (v_team or vb.vendor_id = v_vendor)), '[]'::jsonb),
      'part_classes', jsonb_build_array(
        jsonb_build_object('key','genuine','label_en','Genuine','label_ar','أصلي'),
        jsonb_build_object('key','oem','label_en','OEM','label_ar','OEM'),
        jsonb_build_object('key','commercial','label_en','Aftermarket','label_ar','تجاري'),
        jsonb_build_object('key','aftermarket_a','label_en','Aftermarket Grade A','label_ar','تجاري درجة أولى'),
        jsonb_build_object('key','aftermarket_b','label_en','Aftermarket Grade B','label_ar','تجاري درجة ثانية'),
        jsonb_build_object('key','used','label_en','Used','label_ar','مستعمل'),
        jsonb_build_object('key','remanufactured','label_en','Remanufactured','label_ar','مُجدَّد'))
    )
  ));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.uploaded_data_get(p_template_key text DEFAULT NULL::text, p_status text DEFAULT NULL::text, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 50, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  return jsonb_build_object('status', true, 'message', 'ok', 'data', jsonb_build_object(
    'is_team', v_team,

    'batches', coalesce((
      select jsonb_agg(jsonb_build_object(
               'batch_id', b.batch_id, 'template_key', b.template_key,
               'template_label', tpl.label_ar, 'file_name', b.file_name,
               'status', b.status, 'source_kind', b.source_kind,
               'source_id', b.source_id,
               'source_label', b.source_label, 'branch_scope', b.branch_scope,
               'branches', qvm_new_apps.upload_batch_branches_json(b.batch_id),
               'rows_total', b.rows_total, 'rows_ready', b.rows_ready,
               'rows_disabled', b.rows_disabled, 'rows_rejected', b.rows_rejected,
               'rows_duplicate', b.rows_duplicate, 'rows_held', b.rows_held,
               'uploaded_by_name', u.user_name,
               'created_at', b.created_at, 'published_at', b.published_at,
               'delete_request', (
                 select jsonb_build_object('request_id', r.request_id, 'status', r.status,
                                           'reason', r.reason, 'requested_at', r.requested_at,
                                           'requested_by_name', ru.user_name)
                   from qvm_new_apps.upload_delete_requests r
                   left join qvm_new_apps.user_data ru on ru.user_id = r.requested_by
                  where r.batch_id = b.batch_id and r.status = 'pending'
                  limit 1),
               'live_rows', case b.template_key
                 when 'agency_price_list' then (select count(*) from qvm_new_apps.agency_price_reference x where x.batch_id = b.batch_id)
                 when 'stock_on_hand'     then (select count(*) from qvm_new_apps.inventory_stock x where x.batch_id = b.batch_id)
                 when 'past_purchases'    then (select count(*) from qvm_new_apps.part_purchase_history x where x.batch_id = b.batch_id)
                 when 'aliases'           then (select count(*) from qvm_new_apps.part_aliases x where x.batch_id = b.batch_id)
                 when 'offers'            then (select count(*) from qvm_new_apps.part_offers x where x.batch_id = b.batch_id)
                 when 'group_import_request' then (select count(*) from qvm_new_apps.group_import_requests x where x.batch_id = b.batch_id)
                 when 'stock_auction'     then (select count(*) from qvm_new_apps.stock_auction_items x where x.batch_id = b.batch_id)
                 else 0 end)
             order by b.created_at desc)
        from (select * from qvm_new_apps.upload_batches
               where (p_template_key is null or template_key = p_template_key)
                 and (p_status is null or status = p_status)
                 and (p_search is null or file_name ilike '%' || p_search || '%'
                      or coalesce(source_label,'') ilike '%' || p_search || '%')
                 and (qvm_new_apps.is_qparts_team()
                      or (source_kind = 'vendor' and source_id = qvm_new_apps.current_upload_vendor_id()))
               order by created_at desc limit p_limit offset p_offset) b
        join qvm_new_apps.upload_templates tpl on tpl.template_key = b.template_key
        left join qvm_new_apps.user_data u on u.user_id = b.uploaded_by), '[]'::jsonb),

    'total', (select count(*) from qvm_new_apps.upload_batches b
               where (p_template_key is null or b.template_key = p_template_key)
                 and (p_status is null or b.status = p_status)
                 and (p_search is null or b.file_name ilike '%' || p_search || '%'
                      or coalesce(b.source_label,'') ilike '%' || p_search || '%')
                 and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),

    -- Rows analysed and not yet saved, keyed by file type. Deliberately not filtered by
    -- p_template_key: the tab strip draws every type at once, and a map that only knows about
    -- the tab you are standing on is not a map.
    'pending_rows', coalesce((
      select jsonb_object_agg(p.template_key, p.n)
        from (select b.template_key, sum(b.rows_ready) as n
                from qvm_new_apps.upload_batches b
               where b.status = 'preview' and b.rows_ready > 0
                 and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))
               group by b.template_key) p), '{}'::jsonb),

    'counters', (select jsonb_build_object(
        'files', count(*), 'accepted', coalesce(sum(rows_ready), 0),
        'rejected', coalesce(sum(rows_rejected), 0),
        'awaiting_rule', coalesce(sum(rows_disabled), 0),
        'held', coalesce(sum(rows_held), 0))
        from qvm_new_apps.upload_batches b
       where (p_template_key is null or b.template_key = p_template_key)
         and (p_status is null or b.status = p_status)
         and (p_search is null or b.file_name ilike '%' || p_search || '%'
              or coalesce(b.source_label,'') ilike '%' || p_search || '%')
         and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),

    'pending_deletes', (select count(*) from qvm_new_apps.upload_delete_requests r
                         join qvm_new_apps.upload_batches b on b.batch_id = r.batch_id
                        where r.status = 'pending'
                          and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))),

    'vendors', case when v_team then coalesce((
        select jsonb_agg(jsonb_build_object('id', v.vendor_id, 'name', v.vendor_name)
               order by v.vendor_name)
          from qvm_new_apps.vendors v
         where qvm_new_apps.upload_vendor_visible(v.vendor_id)), '[]'::jsonb) else '[]'::jsonb end,

    'templates', coalesce((
      select jsonb_agg(jsonb_build_object(
               'template_key', t.template_key, 'label_ar', t.label_ar,
               'files', (select count(*) from qvm_new_apps.upload_batches b
                          where b.template_key = t.template_key
                            and (p_status is null or b.status = p_status)
                            and (p_search is null or b.file_name ilike '%' || p_search || '%'
                                 or coalesce(b.source_label,'') ilike '%' || p_search || '%')
                            and (v_team or (b.source_kind = 'vendor' and b.source_id = v_vendor))))
             order by t.sort_order)
        from qvm_new_apps.upload_templates t
       where v_team or t.allowed_for_vendor), '[]'::jsonb)
  ));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_stage(p_template_key text, p_file_name text, p_rows jsonb, p_source_kind text DEFAULT 'vendor'::text, p_source_id bigint DEFAULT NULL::bigint, p_source_label text DEFAULT NULL::text, p_branch_scope text DEFAULT 'all'::text, p_branch_ids bigint[] DEFAULT '{}'::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_batch bigint; v_row jsonb; v_clean jsonb; v_n integer := 0;
  v_seen text[] := '{}'; v_state text;
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_kind text := p_source_kind; v_sid bigint := p_source_id; v_label text := p_source_label;
  v_ids bigint[] := coalesce(p_branch_ids, '{}');
  v_scoped boolean; v_strict boolean;
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
  end if;

  -- Agency lists, stock and past purchases are a vendor's and land on that vendor's branches:
  -- the file names the vendor, and the chosen branches are kept as rows on the batch. «All
  -- branches» is resolved here to the branches the vendor has today, so it is a list and not a
  -- promise about branches opened later. Ids that are not this vendor's are dropped rather than
  -- failed on; an empty result is refused, because a file that lands nowhere is not saved.
  select t.needs_branch into v_scoped from qvm_new_apps.upload_templates t
   where t.template_key = p_template_key;
  v_strict := qvm_new_apps.upload_template_is_branch_bound(p_template_key);
  if v_strict and (v_kind <> 'vendor' or v_sid is null) then
    return jsonb_build_object('status', false,
      'message', 'اختر المورّد الذي يخص هذا الملف', 'data', null);
  end if;
  -- A company admin files under the company's own vendors only; the picker shows no others,
  -- and a request that names one anyway is refused rather than trusted.
  if v_team and v_sid is not null and not qvm_new_apps.upload_vendor_visible(v_sid::integer) then
    return jsonb_build_object('status', false,
      'message', 'هذا المورّد لا يتبع شركتك', 'data', null);
  end if;
  if coalesce(v_scoped, false) and v_kind = 'vendor' and v_sid is not null then
    v_ids := qvm_new_apps.upload_branches_resolve(v_sid::integer, p_branch_scope, v_ids, v_strict);
    if v_strict and coalesce(array_length(v_ids, 1), 0) = 0 then
      return jsonb_build_object('status', false,
        'message', case when p_branch_scope = 'specific'
                        then 'اختر فرعًا واحدًا على الأقل من فروع المورّد'
                        else 'ليس لهذا المورّد فروع نشطة — أضف فرعًا له أولًا' end, 'data', null);
    end if;
    if not v_strict and p_branch_scope = 'specific' and coalesce(array_length(v_ids, 1), 0) = 0 then
      return jsonb_build_object('status', false,
        'message', 'لم تُختَر فروع تخصّ هذا المورّد', 'data', null);
    end if;
  elsif not v_team and p_branch_scope = 'specific' and coalesce(array_length(v_ids, 1), 0) = 0 then
    return jsonb_build_object('status', false,
      'message', 'لم تُختَر فروع تخصّك', 'data', null);
  end if;

  insert into qvm_new_apps.upload_batches
    (template_key, file_name, source_kind, source_id, source_label,
     branch_scope, branch_ids, branch_kind, status, uploaded_by)
  values (p_template_key, p_file_name, v_kind, v_sid, v_label,
          p_branch_scope, v_ids, 'vendor', 'preview', auth.uid())
  returning batch_id into v_batch;

  insert into qvm_new_apps.upload_batch_branches (batch_id, vendor_branch_id)
  select v_batch, x.id from unnest(v_ids) as x(id)
  on conflict do nothing;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    v_n := v_n + 1;
    v_clean := qvm_new_apps.upload_clean_row(v_row, p_template_key, v_kind, v_sid);
    v_state := v_clean->>'state';
    if v_state not in ('rejected', 'held') and (v_clean->>'clean_part_number') = any(v_seen) then
      v_state := 'duplicate';
    elsif v_state not in ('rejected', 'held') then
      v_seen := v_seen || (v_clean->>'clean_part_number');
    end if;

    insert into qvm_new_apps.upload_rows
      -- raw_source is the file as the supplier wrote it and is never rewritten. Without it,
      -- applying a column map a second time reads our own canonical names back as if they were
      -- the file's headers, offers to ignore them, and destroys the columns it just filled.
      (batch_id, row_number, raw, raw_source, source_part_number, clean_part_number,
       display_part_number, source_name, clean_name, source_name_en, clean_name_en, name_is_guess,
       matched_rule_id, brand,
       part_class, country_of_origin, state, reason)
    values (v_batch, v_n, v_row, v_row,
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
    rows_held      = (select count(*) from qvm_new_apps.upload_rows where batch_id = v_batch and state = 'held'),
    updated_at     = now()
  where b.batch_id = v_batch;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (v_batch, 'stage', jsonb_build_object('file', p_file_name, 'rows', v_n), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', (select to_jsonb(b) || jsonb_build_object('branches', qvm_new_apps.upload_batch_branches_json(b.batch_id))
               from qvm_new_apps.upload_batches b where b.batch_id = v_batch));
end
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.upload_batch_set_source(p_batch_id bigint, p_vendor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_name text;
  v_batch record;
  v_strict boolean;
  v_ids bigint[];
  v_scope text;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  select * into v_batch from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_batch.batch_id is null then
    return jsonb_build_object('status', false, 'message', 'not found', 'data', null);
  end if;
  v_strict := qvm_new_apps.upload_template_is_branch_bound(v_batch.template_key);

  -- Rows of an agency list, a stock file or a purchase file are stamped with the vendor and the
  -- branch when they are published. Moving the file to another vendor afterwards would leave
  -- those rows where they were, so the file's data is removed first, then it is re-attached.
  if v_strict and v_batch.status = 'published' then
    return jsonb_build_object('status', false,
      'message', 'هذا الملف منشور باسم مورّد؛ احذف بياناته المنشورة أولًا ثم غيّر المورّد', 'data', null);
  end if;

  if p_vendor_id is null then
    if v_strict then
      return jsonb_build_object('status', false,
        'message', 'هذا النوع من الملفات يخص مورّدًا ولا يُحفظ بلا مورّد', 'data', null);
    end if;
    update qvm_new_apps.upload_batches
       set source_kind = 'internal', source_id = null, source_label = null, updated_at = now()
     where batch_id = p_batch_id;
    delete from qvm_new_apps.upload_batch_branches where batch_id = p_batch_id;
  else
    select v.vendor_name into v_name from qvm_new_apps.vendors v where v.vendor_id = p_vendor_id;
    if v_name is null then
      return jsonb_build_object('status', false, 'message', 'المورّد غير موجود', 'data', null);
    end if;
    if not qvm_new_apps.upload_vendor_visible(p_vendor_id::integer) then
      return jsonb_build_object('status', false, 'message', 'هذا المورّد لا يتبع شركتك', 'data', null);
    end if;

    -- The chosen branches were the old vendor's. Whatever of them the new vendor also has is
    -- kept; when nothing carries over, the file covers the new vendor's branches in full, and
    -- the scope says so.
    v_scope := v_batch.branch_scope;
    v_ids := qvm_new_apps.upload_branches_resolve(p_vendor_id::integer, v_scope, v_batch.branch_ids, v_strict);
    if v_strict and coalesce(array_length(v_ids, 1), 0) = 0 and v_scope = 'specific' then
      v_scope := 'all';
      v_ids := qvm_new_apps.upload_branches_resolve(p_vendor_id::integer, 'all', '{}', true);
    end if;
    if v_strict and coalesce(array_length(v_ids, 1), 0) = 0 then
      return jsonb_build_object('status', false,
        'message', 'ليس لهذا المورّد فروع نشطة — أضف فرعًا له أولًا', 'data', null);
    end if;

    update qvm_new_apps.upload_batches
       set source_kind = 'vendor', source_id = p_vendor_id, source_label = v_name,
           branch_scope = v_scope, branch_ids = v_ids, branch_kind = 'vendor', updated_at = now()
     where batch_id = p_batch_id;
    delete from qvm_new_apps.upload_batch_branches where batch_id = p_batch_id;
    insert into qvm_new_apps.upload_batch_branches (batch_id, vendor_branch_id)
    select p_batch_id, x.id from unnest(v_ids) as x(id)
    on conflict do nothing;
  end if;

  insert into qvm_new_apps.upload_batch_log (batch_id, action, detail, changed_by)
  values (p_batch_id, 'set_source',
          jsonb_build_object('vendor_id', p_vendor_id, 'branches', v_ids), auth.uid());

  -- Re-read the file against the newly attached vendor's code rules.
  return qvm_new_apps.upload_batch_recompute(p_batch_id);
end
$function$;
