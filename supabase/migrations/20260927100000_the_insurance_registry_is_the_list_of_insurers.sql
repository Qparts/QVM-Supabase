-- The insurance registry is the list of insurers.
--
-- An insurance customer used to be picked from whatever rows a company had typed into the
-- Insurance Companies module. The insurers licensed in the Kingdom are a known list, so that list
-- now lives here, with its codes (CI1..CI22), and the customer form searches it instead.
--
-- Nothing downstream changes shape: end_customers and quotations keep pointing at
-- insurance_companies. Picking a registry entry finds or creates the company's insurance_companies
-- row for that code, which is what the customer is then linked to — so the module still shows the
-- insurers a company actually uses, and its own fields (tax and registration numbers) still
-- belong to that row.

CREATE TABLE IF NOT EXISTS qvm_new_apps.insurance_registry (
  code       text PRIMARY KEY,
  name_ar    text NOT NULL,
  name_en    text NOT NULL,
  -- A remark worth showing beside the name, e.g. a suspension by the Insurance Authority.
  note       text,
  sort_order integer NOT NULL DEFAULT 100,
  is_active  boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE, DELETE ON qvm_new_apps.insurance_registry TO service_role;

INSERT INTO qvm_new_apps.insurance_registry (code, name_ar, name_en, note, sort_order) VALUES
  ('CI1',  'شركة الراجحي للتأمين التعاوني (تكافل الراجحي)',                 'Takaful Al Rajhi',                                          NULL, 1),
  ('CI2',  'شركة التعاونية للتأمين',                                          'Tawuniya',                                                  NULL, 2),
  ('CI3',  'شركة ليفا للتأمين',                                               'Liva Insurance',                                            NULL, 3),
  ('CI4',  'شركة ولاء للتأمين التعاوني',                                     'Wala''a Cooperative Insurance Company',                     NULL, 4),
  ('CI5',  'شركة المتوسط والخليج للتأمين وإعادة التأمين التعاوني (ميدغلف)',  'Medgulf',                                                   NULL, 5),
  ('CI6',  'شركة ملاذ للتأمين وإعادة التأمين التعاوني',                      'Malath Cooperative Insurance & Reinsurance Company',        NULL, 6),
  ('CI7',  'شركة الدرع العربي للتأمين التعاوني',                             'Arabian Shield Cooperative Insurance Company',              NULL, 7),
  ('CI8',  'الشركة العربية السعودية للتأمين التعاوني (سايكو)',               'Saudi Arabian Cooperative Insurance Company (SAICO)',       NULL, 8),
  ('CI9',  'شركة المجموعة المتحدة للتأمين التعاوني (أسيج)',                  'United Cooperative Assurance Company (UCA)',                NULL, 9),
  ('CI10', 'شركة جي إي جي (GIG) السعودية',                                    'Gulf Insurance Group (GIG) Saudi Arabia',                   NULL, 10),
  ('CI11', 'شركة سلامة للتأمين التعاوني',                                    'Salama Cooperative Insurance Company',                      NULL, 11),
  ('CI12', 'شركة بروج للتأمين التعاوني',                                     'Buruj Cooperative Insurance Company',                       NULL, 12),
  ('CI13', 'شركة الصقر للتأمين التعاوني',                                    'Al-Sagr Cooperative Insurance Company',                     NULL, 13),
  ('CI14', 'شركة الوطنية للتأمين',                                            'Wataniya Insurance Company',                                NULL, 14),
  ('CI15', 'شركة التأمين العربية التعاونية',                                 'Arabia Insurance Cooperative Company',                      NULL, 15),
  ('CI16', 'الشركة الخليجية العامة للتأمين التعاوني',                        'Gulf General Cooperative Insurance Company',                NULL, 16),
  ('CI17', 'شركة الاتحاد للتأمين التعاوني',                                  'Al-Etihad Cooperative Insurance Company',                   NULL, 17),
  ('CI18', 'شركة اتحاد الخليج الأهلية للتأمين التعاوني',                     'Gulf Union Alahlia Cooperative Insurance Company',          NULL, 18),
  ('CI19', 'شركة متكاملة للتأمين',                                            'Metintegrated Insurance Company',                           NULL, 19),
  ('CI20', 'شركة عناية السعودية للتأمين التعاوني',                           'Saudi Enaya Cooperative Insurance Company',                 NULL, 20),
  ('CI21', 'شركة أمانة للتأمين التعاوني',                                    'Amana Cooperative Insurance Company',                       NULL, 21),
  ('CI22', 'الشركة المتحدة للتأمين التعاوني',                                'United Cooperative Assurance Company',
           'تنبيه: موقفة مؤقتاً عن تأمين المركبات من هيئة التأمين', 22)
ON CONFLICT (code) DO UPDATE
  SET name_ar = EXCLUDED.name_ar, name_en = EXCLUDED.name_en, note = EXCLUDED.note, sort_order = EXCLUDED.sort_order;

-- An insurer row made from the registry remembers which entry it came from, once per company.
ALTER TABLE qvm_new_apps.insurance_companies ADD COLUMN IF NOT EXISTS registry_code text
  REFERENCES qvm_new_apps.insurance_registry(code);
CREATE UNIQUE INDEX IF NOT EXISTS insurance_companies_registry_code_uk
  ON qvm_new_apps.insurance_companies (client_id, registry_code) WHERE registry_code IS NOT NULL;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_insurance_registry()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT CASE WHEN auth.uid() IS NULL THEN jsonb_build_object('success', false, 'error', 'Not signed in')
         ELSE jsonb_build_object('success', true, 'data', COALESCE((
           SELECT jsonb_agg(jsonb_build_object('code', r.code, 'name_ar', r.name_ar, 'name_en', r.name_en, 'note', r.note)
                            ORDER BY r.sort_order, r.code)
             FROM qvm_new_apps.insurance_registry r WHERE r.is_active), '[]'::jsonb)) END;
$$;

-- The company's insurer row for a registry entry, made on first use. The company is the one
-- given, else the customer's owner's (a workshop's or a vendor's primary company), else the
-- caller's own. Returns the row the customer is linked to.
CREATE OR REPLACE FUNCTION qvm_new_apps.ensure_insurance_company(
  p_code text, p_owner_kind text DEFAULT NULL, p_owner_id bigint DEFAULT NULL, p_company_id integer DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); r qvm_new_apps.insurance_registry; v_company integer; v_id bigint; v_row qvm_new_apps.insurance_companies;
BEGIN
  IF v_uid IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not signed in'); END IF;
  SELECT * INTO r FROM qvm_new_apps.insurance_registry WHERE code = upper(btrim(p_code)) AND is_active;
  IF r.code IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Unknown insurance company code'); END IF;

  v_company := p_company_id;
  IF v_company IS NULL AND p_owner_kind = 'workshop' AND p_owner_id IS NOT NULL THEN
    SELECT wc.company_id INTO v_company FROM qvm_new_apps.workshop_companies wc
     WHERE wc.workshop_id = p_owner_id ORDER BY wc.is_primary DESC, wc.company_id LIMIT 1;
  ELSIF v_company IS NULL AND p_owner_kind = 'vendor' AND p_owner_id IS NOT NULL THEN
    SELECT vc.company_id INTO v_company FROM qvm_new_apps.vendor_companies vc
     WHERE vc.vendor_id = p_owner_id ORDER BY vc.is_primary DESC, vc.company_id LIMIT 1;
  END IF;
  IF v_company IS NULL THEN
    SELECT c.company_id INTO v_company FROM qvm_new_apps.permission_companies(v_uid) c ORDER BY c.company_id LIMIT 1;
  END IF;
  IF v_company IS NULL THEN
    -- The platform's own admin with no company: fall back to the first company on record.
    SELECT cc.company_id INTO v_company FROM qvm_new_apps.client_companies cc ORDER BY cc.company_id LIMIT 1;
  END IF;
  IF v_company IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'No company to file the insurer under'); END IF;
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_internal_user()
          OR qvm_new_apps.can_admin_company(v_company)
          OR (p_owner_kind = 'workshop' AND qvm_new_apps.can_admin_workshop(p_owner_id))
          OR (p_owner_kind = 'vendor'   AND qvm_new_apps.can_admin_vendor(p_owner_id::integer))) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied');
  END IF;

  SELECT id INTO v_id FROM qvm_new_apps.insurance_companies WHERE client_id = v_company AND registry_code = r.code;
  IF v_id IS NULL THEN
    INSERT INTO qvm_new_apps.insurance_companies (client_id, name, name_en, registry_code, created_at, updated_at)
    VALUES (v_company, r.name_ar, r.name_en, r.code, now(), now())
    ON CONFLICT (client_id, registry_code) WHERE registry_code IS NOT NULL DO UPDATE SET updated_at = now()
    RETURNING id INTO v_id;
  END IF;
  SELECT * INTO v_row FROM qvm_new_apps.insurance_companies WHERE id = v_id;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'id', v_row.id, 'code', r.code, 'name', v_row.name, 'name_en', v_row.name_en,
    'tax_number', v_row.tax_number, 'cr_number', v_row.cr_number, 'note', r.note, 'company_id', v_company));
END $$;

CREATE OR REPLACE FUNCTION public.list_insurance_registry() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.list_insurance_registry() $$;
CREATE OR REPLACE FUNCTION public.ensure_insurance_company(p_code text, p_owner_kind text DEFAULT NULL, p_owner_id bigint DEFAULT NULL, p_company_id integer DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.ensure_insurance_company(p_code, p_owner_kind, p_owner_id, p_company_id) $$;

-- The customer tree says which registry entry each insurer row came from, so the edit form can
-- show the same pick again.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_get_customer_tree()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_uid uuid := auth.uid(); v_res jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  WITH customer_json AS (
    SELECT c.end_customer_id,
           jsonb_build_object(
             'end_customer_id', c.end_customer_id,
             'display_name', c.name,
             'customer_kind', c.customer_kind,
             'customer_code', c.customer_code,
             'insurance_company_id', c.insurance_company_id,
             'tax_number', c.tax_number,
             -- Identity, as the customer form collects it.
             'name_en', ec.name_en,
             'cr_kind', ec.cr_kind,
             'cr_number', ec.cr_number,
             'documents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                        'file_id', f.id, 'doc_type', COALESCE(f.doc_type, f.field_id),
                                        'file_path', f.file_path, 'doc_number', f.doc_number,
                                        'expires_on', f.expires_on, 'created_at', f.created_at)
                                      ORDER BY f.created_at DESC)
                                     FROM qvm_new_apps.files f
                                    WHERE f.module_type = 'end_customers' AND f.module_id = c.end_customer_id), '[]'::jsonb),
             'contact_person', c.contact_person,
             'phone', c.phone,
             'email', c.email,
             'is_active', c.is_active,
             'requires_customer_approval', c.requires_customer_approval,
             'requires_workshop_approval', c.requires_workshop_approval,
             'branch_count', c.branch_count,
             'user_count', c.user_count,
             'branches', COALESCE((
               SELECT jsonb_agg(jsonb_build_object(
                        'end_customer_branch_id', b.end_customer_branch_id,
                        'display_name', b.name,
                        'city', bc.name,
                        'city_id', b.city_id,
                        'is_active', b.is_active,
                        'address_count', b.address_count,
                        'branch_code', eb.branch_code,
                        'brand_ids', COALESCE(to_jsonb(eb.brand_ids), '[]'::jsonb),
                        'part_category_ids', COALESCE(to_jsonb(eb.part_category_ids), '[]'::jsonb),
                        'banks', COALESCE(eb.banks, '[]'::jsonb),
                        'account_type', eb.account_type,
                        'credit_limit', eb.credit_limit,
                        'credit_term_days', eb.credit_term_days,
                        'hours_mode', eb.hours_mode,
                        'working_hours', COALESCE(eb.working_hours, '[]'::jsonb),
                        'names', COALESCE((SELECT jsonb_agg(jsonb_build_object('language_id', bd.language_id, 'name', bd.name)
                                                            ORDER BY bd.language_id)
                                             FROM qvm_new_apps.end_customer_branches_descriptions bd
                                            WHERE bd.end_customer_branch_id = b.end_customer_branch_id), '[]'::jsonb))
                      ORDER BY b.name)
                 FROM qvm_new_apps.v_end_customer_branches b
                 JOIN qvm_new_apps.end_customer_branches eb ON eb.end_customer_branch_id = b.end_customer_branch_id
                 LEFT JOIN qvm_new_apps.v_cities bc ON bc.city_id = b.city_id
                WHERE b.end_customer_id = c.end_customer_id), '[]'::jsonb)
           ) AS js
    FROM qvm_new_apps.v_end_customers c
    JOIN qvm_new_apps.end_customers ec ON ec.end_customer_id = c.end_customer_id
  ),
  -- Every workshop and vendor the caller can administer, as one list: on this screen they are the
  -- same kind of thing — somebody who has customers.
  owners AS (
    SELECT 'workshop'::text AS owner_kind, w.workshop_id::bigint AS owner_id, vw.name,
           w.workshop_code AS code,
           (SELECT jsonb_agg(x.company_id) FROM qvm_new_apps.workshop_companies x
             WHERE x.workshop_id = w.workshop_id) AS company_ids
      FROM qvm_new_apps.client_workshops w
      JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = w.workshop_id
     WHERE qvm_new_apps.can_admin_workshop(w.workshop_id)
    UNION ALL
    SELECT 'vendor', v.vendor_id::bigint, vv.name, v.vendor_code,
           (SELECT jsonb_agg(x.company_id) FROM qvm_new_apps.vendor_companies x
             WHERE x.vendor_id = v.vendor_id)
      FROM qvm_new_apps.vendors v
      JOIN qvm_new_apps.v_vendors vv ON vv.vendor_id = v.vendor_id
     WHERE qvm_new_apps.can_admin_vendor(v.vendor_id)
  )
  SELECT jsonb_build_object('success', true, 'data', jsonb_build_object(
    'languages', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.sort_order, l.language_id)
                             FROM qvm_new_apps.languages l WHERE l.is_active), '[]'::jsonb),
    'insurance_companies', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', ic.id, 'name', ic.name,
                                                       'name_en', ic.name_en, 'tax_number', ic.tax_number, 'cr_number', ic.cr_number,
                                                       'registry_code', ic.registry_code)
                                                     ORDER BY ic.name)
                                       FROM qvm_new_apps.insurance_companies ic), '[]'::jsonb),
    'unassigned', CASE WHEN qvm_new_apps.is_qparts_admin(v_uid) THEN
      COALESCE((SELECT jsonb_agg(cj.js ORDER BY cj.js->>'display_name')
                  FROM customer_json cj
                 WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.end_customer_owners o
                                    WHERE o.end_customer_id = cj.end_customer_id)), '[]'::jsonb)
      ELSE '[]'::jsonb END,
    'companies', COALESCE((
      SELECT jsonb_agg(co ORDER BY co->>'display_name')
      FROM (
        SELECT jsonb_build_object(
          'company_id', c.company_id,
          'display_name', vcm.name,
          'owners', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                     'owner_kind', o.owner_kind,
                     'owner_id', o.owner_id,
                     'display_name', o.name,
                     'code', o.code,
                     'customers', COALESCE((
                       SELECT jsonb_agg(cj.js ORDER BY cj.js->>'display_name')
                         FROM customer_json cj
                         JOIN qvm_new_apps.end_customer_owners eo
                           ON eo.end_customer_id = cj.end_customer_id
                          AND ((o.owner_kind = 'workshop' AND eo.workshop_id = o.owner_id)
                            OR (o.owner_kind = 'vendor'   AND eo.vendor_id = o.owner_id))), '[]'::jsonb))
                   ORDER BY o.owner_kind, o.name)
              FROM owners o
             WHERE o.company_ids @> to_jsonb(c.company_id)), '[]'::jsonb)
        ) AS co
        FROM qvm_new_apps.client_companies c
        JOIN qvm_new_apps.v_client_companies vcm ON vcm.company_id = c.company_id
       WHERE qvm_new_apps.can_admin_company(c.company_id)
      ) s), '[]'::jsonb)
  )) INTO v_res;

  RETURN v_res;
END $function$;
