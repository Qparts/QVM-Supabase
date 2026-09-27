-- A branch takes automatic RFQs only when someone turns it on.
--
-- The flag shipped on by default. It should be the other way round: a branch is out of the
-- automatic sends until an admin or the vendor opts it in. The column default, the rows written
-- since (none of which anyone has chosen yet), and every fallback in the branch functions now
-- say false. Function bodies are the 20260928100000 ones with only that constant changed.

ALTER TABLE qvm_new_apps.vendor_branches ALTER COLUMN auto_receive_rfqs SET DEFAULT false;
UPDATE qvm_new_apps.vendor_branches SET auto_receive_rfqs = false;

CREATE OR REPLACE FUNCTION qvm_new_apps._apply_vendor_branch_details(p_vendor_branch_id bigint, p jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF p IS NULL OR jsonb_typeof(p) <> 'object' THEN RETURN; END IF;
  IF p ? 'hours_mode' AND NULLIF(btrim(p->>'hours_mode'), '') IS NOT NULL AND (p->>'hours_mode') NOT IN ('247', 'schedule') THEN
    RAISE EXCEPTION 'Unknown working-hours mode';
  END IF;
  IF p ? 'account_type' AND NULLIF(btrim(p->>'account_type'), '') IS NOT NULL AND (p->>'account_type') NOT IN ('credit', 'cash') THEN
    RAISE EXCEPTION 'Unknown account type';
  END IF;
  UPDATE qvm_new_apps.vendor_branches b
     SET branch_code   = CASE WHEN p ? 'branch_code' THEN NULLIF(btrim(p->>'branch_code'), '') ELSE b.branch_code END,
         brands        = CASE WHEN p ? 'brand_ids' THEN COALESCE(p->'brand_ids', '[]'::jsonb) ELSE b.brands END,
         categories    = CASE WHEN p ? 'part_category_ids' THEN COALESCE(p->'part_category_ids', '[]'::jsonb) ELSE b.categories END,
         -- Stored with the keys the vendor portal reads (bank_name, bank_account_name, bank_iban)
         -- and the English name beside them.
         banks         = CASE WHEN p ? 'banks' THEN COALESCE((SELECT jsonb_agg(jsonb_build_object(
                             'bank_name', COALESCE(x->>'bank_name', ''),
                             'bank_account_name', COALESCE(x->>'account_name_ar', x->>'bank_account_name', ''),
                             'bank_account_name_en', COALESCE(x->>'account_name_en', ''),
                             'bank_iban', COALESCE(x->>'iban', x->>'bank_iban', ''),
                             'bank_and_cr_files', COALESCE(x->'bank_and_cr_files', '[]'::jsonb)))
                           FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p->'banks') = 'array' THEN p->'banks' ELSE '[]'::jsonb END) x), '[]'::jsonb)
                         ELSE b.banks END,
         auto_receive_rfqs = CASE WHEN p ? 'auto_receive_rfqs' THEN COALESCE((p->>'auto_receive_rfqs')::boolean, false) ELSE b.auto_receive_rfqs END,
         account_type  = CASE WHEN p ? 'account_type' THEN NULLIF(btrim(p->>'account_type'), '') ELSE b.account_type END,
         payment_method = CASE WHEN p ? 'account_type' THEN CASE p->>'account_type' WHEN 'cash' THEN 'Cash' WHEN 'credit' THEN 'Credit' ELSE b.payment_method END ELSE b.payment_method END,
         credit_limit  = CASE WHEN p ? 'credit_limit' THEN NULLIF(regexp_replace(COALESCE(p->>'credit_limit', ''), '[^0-9.]', '', 'g'), '')::numeric ELSE b.credit_limit END,
         credit_term_days = CASE WHEN p ? 'credit_term_days' THEN NULLIF(regexp_replace(COALESCE(p->>'credit_term_days', ''), '[^0-9]', '', 'g'), '')::int ELSE b.credit_term_days END,
         hours_mode    = CASE WHEN p ? 'hours_mode' THEN NULLIF(btrim(p->>'hours_mode'), '') ELSE b.hours_mode END,
         working_hours = CASE WHEN p ? 'working_hours' THEN COALESCE(p->'working_hours', '[]'::jsonb) ELSE b.working_hours END,
         updated_at = now()
   WHERE b.vendor_branch_id = p_vendor_branch_id;
END
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_vendor_tree()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  -- Every level opens the tree and sees what it runs: Qparts everything, a Company Admin the
  -- vendors of their companies, a Vendor Admin their vendor, a vendor user their branches.
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)
          OR EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_uid AND ud.user_type = 205
                        AND ud.user_vendor IS NOT NULL AND ud.deleted_at IS NULL)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  WITH vendor_json AS (
    SELECT v.vendor_id,
           jsonb_build_object(
             'vendor_id', v.vendor_id,
             'display_name', COALESCE(vv.name, v.vendor_name),
             'vendor_code', v.vendor_code,
             'vendor_type', v.vendor_type,
             'email', v.email,
             'can_edit', qvm_new_apps.can_admin_vendor(v.vendor_id),
             -- Identity and terms, as the vendor form collects them.
             'vendor_type_id', v.vendor_type_id,
             'tax_number', v.tax_number,
             'cr_kind', v.cr_kind,
             'cr_number', v.commercial_registeration_number,
             'receives_quotations', COALESCE(v.receives_quotations, true),
             'documents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                        'file_id', f.id, 'doc_type', COALESCE(f.doc_type, f.field_id),
                                        'file_path', f.file_path, 'doc_number', f.doc_number,
                                        'expires_on', f.expires_on, 'created_at', f.created_at)
                                      ORDER BY f.created_at DESC)
                                     FROM qvm_new_apps.files f
                                    WHERE f.module_type = 'vendors' AND f.module_id = v.vendor_id), '[]'::jsonb),
             'city', vc.name,
             'city_id', v.city_id,
             'branch_count', vv.branch_count,
             'company_ids', COALESCE((SELECT jsonb_agg(x.company_id ORDER BY x.company_id)
                                        FROM qvm_new_apps.vendor_companies x
                                       WHERE x.vendor_id = v.vendor_id), '[]'::jsonb),
             'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', d.language_id, 'name', d.name)
                                                 ORDER BY d.language_id)
                                  FROM qvm_new_apps.vendors_descriptions d
                                 WHERE d.vendor_id = v.vendor_id), '[]'::jsonb),
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'vendor_branch_id', b.vendor_branch_id,
                        'display_name', b.name,
                        'city', bc.name,
                        'city_id', b.city_id,
                        'is_active', b.is_active,
                        'address_count', b.address_count,
                        'can_edit', qvm_new_apps.can_admin_vendor_branch(b.vendor_branch_id),
                        'branch_code', vb.branch_code,
                        'brand_ids', COALESCE(vb.brands, '[]'::jsonb),
                        'part_category_ids', COALESCE(vb.categories, '[]'::jsonb),
                        -- The bank rows in the shape the shared form uses; the vendor portal's keys stay on the row.
                        'banks', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                     'bank_name', COALESCE(x->>'bank_name', ''),
                                     'account_name_ar', COALESCE(x->>'bank_account_name', ''),
                                     'account_name_en', COALESCE(x->>'bank_account_name_en', ''),
                                     'iban', COALESCE(x->>'bank_iban', '')))
                                   FROM jsonb_array_elements(CASE WHEN jsonb_typeof(vb.banks) = 'array' THEN vb.banks ELSE '[]'::jsonb END) x), '[]'::jsonb),
                        'account_type', vb.account_type,
                        'credit_limit', vb.credit_limit,
                        'credit_term_days', vb.credit_term_days,
                        'hours_mode', vb.hours_mode,
                        'auto_receive_rfqs', COALESCE(vb.auto_receive_rfqs, false),
                        'working_hours', COALESCE(vb.working_hours, '[]'::jsonb),
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', bd.language_id, 'name', bd.name)
                                                            ORDER BY bd.language_id)
                                             FROM qvm_new_apps.vendor_branches_descriptions bd
                                            WHERE bd.vendor_branch_id = b.vendor_branch_id), '[]'::jsonb))
                      ORDER BY b.name)
                 FROM qvm_new_apps.v_vendor_branches b
                 JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = b.vendor_branch_id
                 LEFT JOIN qvm_new_apps.v_cities bc ON bc.city_id = b.city_id
                WHERE b.vendor_id = v.vendor_id
                  -- A vendor user sees the branches they are assigned to; the vendor's admins see them all.
                  AND (qvm_new_apps.can_admin_vendor(v.vendor_id)
                       OR EXISTS (SELECT 1 FROM qvm_new_apps.vendor_branch_users vbu
                                   WHERE vbu.user_id = v_uid AND vbu.vendor_branch_id = b.vendor_branch_id))), '[]'::jsonb)
           ) AS js
    FROM qvm_new_apps.vendors v
    JOIN qvm_new_apps.v_vendors vv ON vv.vendor_id = v.vendor_id
    LEFT JOIN qvm_new_apps.v_cities vc ON vc.city_id = v.city_id
   WHERE qvm_new_apps.can_admin_vendor(v.vendor_id)
      OR EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud WHERE ud.user_id = v_uid AND ud.user_vendor = v.vendor_id AND ud.deleted_at IS NULL)
  )
  SELECT jsonb_build_object('success', true, 'data', jsonb_build_object(
    'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                             FROM qvm_new_apps.languages l WHERE l.is_active), '[]'::jsonb),
    -- A vendor nobody has linked belongs to no company, so it is nobody's but Qparts'.
    'unassigned', CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN
      COALESCE((SELECT jsonb_agg(vj.js ORDER BY vj.js->>'display_name')
                  FROM vendor_json vj
                 WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.vendor_companies x
                                    WHERE x.vendor_id = vj.vendor_id)), '[]'::jsonb)
      ELSE '[]'::jsonb END,
    'companies', COALESCE((
      SELECT jsonb_agg(co ORDER BY s.vendor_count DESC, s.created_at DESC NULLS LAST, co->>'display_name')
      FROM (
        SELECT jsonb_build_object(
          'company_id', c.company_id,
          'display_name', vcm.name,
          'created_at', c.created_at,
          'vendor_count', (SELECT count(*) FROM qvm_new_apps.vendor_companies x WHERE x.company_id = c.company_id),
          'vendors', COALESCE((SELECT jsonb_agg(vj.js ORDER BY vj.js->>'display_name')
                                 FROM vendor_json vj
                                 JOIN qvm_new_apps.vendor_companies x
                                   ON x.vendor_id = vj.vendor_id AND x.company_id = c.company_id), '[]'::jsonb)
        ) AS co,
        c.created_at,
        (SELECT count(*) FROM qvm_new_apps.vendor_companies x WHERE x.company_id = c.company_id) AS vendor_count
        FROM qvm_new_apps.client_companies c
        JOIN qvm_new_apps.v_client_companies vcm ON vcm.company_id = c.company_id
       WHERE qvm_new_apps.can_admin_company(c.company_id)
          -- Or a company the caller's vendor sells to: read-only at the company level.
          OR EXISTS (SELECT 1 FROM vendor_json vj JOIN qvm_new_apps.vendor_companies x ON x.vendor_id = vj.vendor_id
                      WHERE x.company_id = c.company_id)
      ) s), '[]'::jsonb),
    'viewer', jsonb_build_object('level',
      CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN 'qparts'
           WHEN qvm_new_apps.is_company_admin(v_uid) THEN 'company'
           WHEN EXISTS (SELECT 1 FROM qvm_new_apps.user_data ud JOIN qvm_new_apps.list_data r ON r.list_data_id = ud.user_role
                         WHERE ud.user_id = v_uid AND r.list_data = 'Vendor Admin') THEN 'vendor'
           ELSE 'branch' END)
  )) INTO v_res;

  RETURN v_res;
END
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendor_branch(p_vendor_id integer, p_branch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_new_id bigint;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF NULLIF(trim(p_branch->>'branch_name'), '') IS NULL OR NULLIF(trim(p_branch->>'city'), '') IS NULL THEN
    RAISE EXCEPTION 'branch_name and city are required';
  END IF;

  INSERT INTO qvm_new_apps.vendor_branches (
    vendor_id, branch_name, city, phone, location_lat, location_lng, address, brands, categories, is_active,
    region, operating_hours, items_type, payment_method, banks,
    location, discount_percent, notify_by_email, notify_by_whatsapp, auto_receive_rfqs
  ) VALUES (
    p_vendor_id,
    p_branch->>'branch_name',
    p_branch->>'city',
    NULLIF(trim(p_branch->>'phone'), ''),
    NULLIF(p_branch->>'location_lat', '')::double precision,
    NULLIF(p_branch->>'location_lng', '')::double precision,
    p_branch->>'address',
    COALESCE(p_branch->'brands', '[]'::jsonb),
    COALESCE(p_branch->'categories', '[]'::jsonb),
    COALESCE((p_branch->>'is_active')::boolean, true),
    CASE WHEN p_branch ? 'region' THEN p_branch->'region' ELSE NULL END,
    CASE WHEN p_branch ? 'operating_hours' THEN p_branch->'operating_hours' ELSE NULL END,
    CASE WHEN p_branch ? 'items_type' THEN p_branch->'items_type' ELSE NULL END,
    NULLIF(p_branch->>'payment_method', ''),
    COALESCE(p_branch->'banks', '[]'::jsonb),
    NULLIF(p_branch->>'location', ''),
    NULLIF(p_branch->>'discount_percent', '')::double precision,
    COALESCE((p_branch->>'notify_by_email')::boolean, true),
    COALESCE((p_branch->>'notify_by_whatsapp')::boolean, false),
    COALESCE((p_branch->>'auto_receive_rfqs')::boolean, false)
  )
  RETURNING vendor_branch_id INTO v_new_id;

  RETURN jsonb_build_object('status', true, 'vendor_branch_id', v_new_id);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_branches(p_vendor_id integer, p_active_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
  v_preferred_branch_id bigint;
BEGIN
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(p_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT v.preferred_branch_id INTO v_preferred_branch_id
  FROM qvm_new_apps.vendors v
  WHERE v.vendor_id = p_vendor_id;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'vendor_branch_id', vb.vendor_branch_id,
           'vendor_id', vb.vendor_id,
           'branch_name', vb.branch_name,
           'city', vb.city,
           'phone', vb.phone,
           'location_lat', vb.location_lat,
           'location_lng', vb.location_lng,
           'address', vb.address,
           'brands', vb.brands,
           'categories', vb.categories,
           'is_active', vb.is_active,
           'is_preferred', (vb.vendor_branch_id = v_preferred_branch_id),
           'region', vb.region,
           'operating_hours', vb.operating_hours,
           'items_type', vb.items_type,
           'payment_method', vb.payment_method,
           'banks', vb.banks,
           'notify_by_email', vb.notify_by_email,
           'notify_by_whatsapp', vb.notify_by_whatsapp,
           'auto_receive_rfqs', COALESCE(vb.auto_receive_rfqs, false)
         ) ORDER BY vb.city, vb.branch_name), '[]'::jsonb)
  INTO v_result
  FROM qvm_new_apps.vendor_branches vb
  WHERE vb.vendor_id = p_vendor_id
    AND (NOT p_active_only OR vb.is_active);

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_vendor_branches_bulk(p_vendor_ids integer[], p_active_only boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  SELECT COALESCE(jsonb_object_agg(vid.vendor_id, COALESCE(b.branches, '[]'::jsonb)), '{}'::jsonb)
  INTO v_result
  FROM unnest(p_vendor_ids) AS vid(vendor_id)
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
             'vendor_branch_id', vb.vendor_branch_id,
             'vendor_id', vb.vendor_id,
             'branch_name', vb.branch_name,
             'city', vb.city,
             'phone', vb.phone,
             'location_lat', vb.location_lat,
             'location_lng', vb.location_lng,
             'address', vb.address,
             'brands', vb.brands,
             'categories', vb.categories,
             'is_active', vb.is_active,
             'region', vb.region,
             'operating_hours', vb.operating_hours,
             'items_type', vb.items_type,
             'payment_method', vb.payment_method,
             'banks', vb.banks,
             'notify_by_email', vb.notify_by_email,
             'notify_by_whatsapp', vb.notify_by_whatsapp,
           'auto_receive_rfqs', COALESCE(vb.auto_receive_rfqs, false)
           ) ORDER BY vb.city, vb.branch_name) AS branches
    FROM qvm_new_apps.vendor_branches vb
    WHERE vb.vendor_id = vid.vendor_id
      AND (NOT p_active_only OR vb.is_active)
  ) b ON true;

  RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.update_vendor_branch(p_vendor_branch_id bigint, p_branch jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_vendor_id integer;
BEGIN
  SELECT vendor_id INTO v_vendor_id FROM qvm_new_apps.vendor_branches WHERE vendor_branch_id = p_vendor_branch_id;
  IF v_vendor_id IS NULL THEN
    RAISE EXCEPTION 'Branch not found';
  END IF;
  IF NOT (qvm_new_apps.is_internal_user() OR qvm_new_apps.is_vendor_admin_for(v_vendor_id)) THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  UPDATE qvm_new_apps.vendor_branches SET
    branch_name = COALESCE(p_branch->>'branch_name', branch_name),
    city = COALESCE(p_branch->>'city', city),
    phone = CASE WHEN p_branch ? 'phone' THEN NULLIF(trim(p_branch->>'phone'), '') ELSE phone END,
    location_lat = CASE WHEN p_branch ? 'location_lat' THEN NULLIF(p_branch->>'location_lat', '')::double precision ELSE location_lat END,
    location_lng = CASE WHEN p_branch ? 'location_lng' THEN NULLIF(p_branch->>'location_lng', '')::double precision ELSE location_lng END,
    address = COALESCE(p_branch->>'address', address),
    brands = COALESCE(p_branch->'brands', brands),
    categories = COALESCE(p_branch->'categories', categories),
    is_active = COALESCE((p_branch->>'is_active')::boolean, is_active),
    region = CASE WHEN p_branch ? 'region' THEN p_branch->'region' ELSE region END,
    operating_hours = CASE WHEN p_branch ? 'operating_hours' THEN p_branch->'operating_hours' ELSE operating_hours END,
    items_type = CASE WHEN p_branch ? 'items_type' THEN p_branch->'items_type' ELSE items_type END,
    payment_method = CASE WHEN p_branch ? 'payment_method' THEN NULLIF(p_branch->>'payment_method', '') ELSE payment_method END,
    banks = CASE WHEN p_branch ? 'banks' THEN p_branch->'banks' ELSE banks END,
    location = CASE WHEN p_branch ? 'location' THEN NULLIF(p_branch->>'location', '') ELSE location END,
    discount_percent = CASE WHEN p_branch ? 'discount_percent' THEN NULLIF(p_branch->>'discount_percent', '')::double precision ELSE discount_percent END,
    notify_by_email = COALESCE((p_branch->>'notify_by_email')::boolean, notify_by_email),
    notify_by_whatsapp = COALESCE((p_branch->>'notify_by_whatsapp')::boolean, notify_by_whatsapp),
    auto_receive_rfqs = COALESCE((p_branch->>'auto_receive_rfqs')::boolean, auto_receive_rfqs),
    updated_at = now()
  WHERE vendor_branch_id = p_vendor_branch_id;

  RETURN jsonb_build_object('status', true);
END;
$function$;
