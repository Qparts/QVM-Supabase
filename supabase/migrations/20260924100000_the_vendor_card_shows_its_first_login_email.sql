-- The vendor card shows its first login's email.
--
-- vendors.email is whatever was typed when the vendor was added: a contact box, a manager's
-- address, sometimes an internal one. What the Vendors page needs to show is who can actually
-- sign in for that vendor — the first vendor admin or vendor user created for it. The dashboard
-- row gains login_email, resolved from user_data by creation time; the vendor's own email column
-- stays in the row for the edit form.
--
-- Function body is the live one on QVM/test with only the new column added.

CREATE OR REPLACE FUNCTION public.get_vendors_dashboard(p_user_id uuid, p_search text DEFAULT NULL::text, p_vendor_types text[] DEFAULT NULL::text[], p_payment_methods text[] DEFAULT NULL::text[], p_brands text[] DEFAULT NULL::text[], p_regions text[] DEFAULT NULL::text[], p_limit integer DEFAULT 10, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_allowed boolean;
  v_total int := 0;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM qvm_new_apps.user_data u
    LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
    WHERE u.user_id = p_user_id
      AND (
        u.user_type = 185
        OR lower(ur.list_data) IN ('admin','finance manager','pricing supervisor','account manager')
      )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  WITH base AS (
    SELECT v.*, pb.vendor_branch_id AS pb_vendor_branch_id,
           pb.region AS pb_region, pb.operating_hours AS pb_operating_hours, pb.brands AS pb_brands,
           pb.items_type AS pb_items_type, pb.payment_method AS pb_payment_method,
           pb.banks AS pb_banks, pb.location AS pb_location,
           pb.discount_percent AS pb_discount_percent,
           pb.notify_by_email AS pb_notify_by_email, pb.notify_by_whatsapp AS pb_notify_by_whatsapp
    FROM qvm_new_apps.vendors v
    LEFT JOIN qvm_new_apps.vendor_branches pb ON pb.vendor_branch_id = v.preferred_branch_id
    WHERE (
      p_search IS NULL OR p_search = '' OR (
        v.vendor_name ILIKE '%'||p_search||'%'
        OR COALESCE(v.zoho_name,'') ILIKE '%'||p_search||'%'
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pb.brands)='array' THEN pb.brands ELSE '[]'::jsonb END) b(val)
          WHERE val ILIKE '%'||p_search||'%'
        )
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pb.region)='array' THEN pb.region ELSE '[]'::jsonb END) r(val)
          WHERE val ILIKE '%'||p_search||'%'
        )
      )
    )
    AND (
      p_vendor_types IS NULL OR EXISTS (
        SELECT 1 FROM unnest(p_vendor_types) t WHERE lower(btrim(t)) = lower(btrim(COALESCE(v.vendor_type,'')))
      )
    )
    AND (
      p_payment_methods IS NULL OR EXISTS (
        SELECT 1
        FROM unnest(p_payment_methods) pm
        WHERE lower(btrim(pm)) = ANY(
          SELECT lower(btrim(x)) FROM regexp_split_to_table(COALESCE(pb.payment_method,''), '\s*,\s*') x
        )
      )
    )
    AND (
      p_brands IS NULL OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pb.brands)='array' THEN pb.brands ELSE '[]'::jsonb END) b(val)
        WHERE lower(btrim(val)) = ANY (SELECT lower(btrim(x)) FROM unnest(p_brands) x)
      )
    )
    AND (
      p_regions IS NULL OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(pb.region)='array' THEN pb.region ELSE '[]'::jsonb END) r(val)
        WHERE lower(btrim(val)) = ANY (SELECT lower(btrim(x)) FROM unnest(p_regions) x)
      )
    )
  ),
  cnt AS (
    SELECT COUNT(*) AS c FROM base
  ),
  paged AS (
    SELECT
      v.vendor_id,
      v.vendor_name,
      v.zoho_name,
      v.vendor_type,
      v.vendor_type_id,
      v.receives_quotations,
      v.preferred_branch_id,
      v.pb_region AS region,
      v.pb_operating_hours AS operating_hours,
      v.pb_brands AS brands,
      v.pb_items_type AS items_type,
      v.pb_payment_method AS payment_method,
      v.tax_number,
      v.commercial_registeration_number,
      v.pb_banks AS banks,
      v.pb_location AS location,
      v.pb_discount_percent AS discount_percent,
      v.email,
      -- The vendor's first login: the earliest vendor admin or vendor user created for it. The
      -- card shows this rather than the vendor record's own address, which is often a contact
      -- box nobody signs in with.
      (SELECT ud.email FROM qvm_new_apps.user_data ud
        WHERE ud.user_type = 205 AND ud.user_vendor = v.vendor_id AND ud.deleted_at IS NULL
        ORDER BY ud.created_at ASC NULLS LAST, ud.user_id
        LIMIT 1) AS login_email,
      v.phone_numbers,
      v.pb_notify_by_email AS notify_by_email,
      v.pb_notify_by_whatsapp AS notify_by_whatsapp,
      v.created_at
    FROM base v
    ORDER BY v.created_at DESC NULLS LAST, v.vendor_id DESC
    LIMIT GREATEST(p_limit, 1) OFFSET GREATEST(p_offset, 0)
  )
  SELECT c.c,
         (SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.created_at DESC NULLS LAST, p.vendor_id DESC), '[]'::jsonb) FROM paged p)
  INTO v_total, v_rows
  FROM cnt c;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$function$;
