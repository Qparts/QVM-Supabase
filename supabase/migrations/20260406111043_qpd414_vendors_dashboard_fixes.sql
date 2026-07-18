-- Synced from QVM/test branch applied migration history (version 20260406111043, name: qpd414_vendors_dashboard_fixes)
BEGIN;

SET search_path TO qvm_new_apps, public;

-- Fix: DISTINCT with ORDER BY inside jsonb_agg not allowed
CREATE OR REPLACE FUNCTION public.list_vendor_filters()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_vendor_types jsonb;
  v_payment_methods jsonb;
  v_brands jsonb;
  v_regions jsonb;
BEGIN
  -- Vendor Types
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_vendor_types
  FROM (
    SELECT DISTINCT initcap(btrim(v.vendor_type)) AS name
    FROM qvm_new_apps.vendors v
    WHERE v.vendor_type IS NOT NULL AND btrim(v.vendor_type) <> ''
  ) s;

  -- Payment Methods (CSV -> distinct -> title case)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_payment_methods
  FROM (
    SELECT DISTINCT initcap(nm) AS name
    FROM (
      SELECT lower(btrim(x)) AS nm
      FROM qvm_new_apps.vendors v,
           regexp_split_to_table(COALESCE(v.payment_method, ''), '\\s*,\\s*') x
      WHERE x IS NOT NULL AND btrim(x) <> ''
    ) t
  ) d;

  -- Brands (jsonb[] -> distinct -> title case)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_brands
  FROM (
    SELECT DISTINCT initcap(btrim(elem)) AS name
    FROM qvm_new_apps.vendors v,
         jsonb_array_elements_text(COALESCE(v.brands, '[]'::jsonb)) elem
    WHERE elem IS NOT NULL AND btrim(elem) <> ''
  ) b;

  -- Regions (jsonb[] -> distinct -> title case)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_regions
  FROM (
    SELECT DISTINCT initcap(btrim(elem)) AS name
    FROM qvm_new_apps.vendors v,
         jsonb_array_elements_text(COALESCE(v.region, '[]'::jsonb)) elem
    WHERE elem IS NOT NULL AND btrim(elem) <> ''
  ) r;

  RETURN jsonb_build_object(
    'vendor_types', v_vendor_types,
    'payment_methods', v_payment_methods,
    'brands', v_brands,
    'regions', v_regions
  );
END;
$$;

REVOKE ALL ON FUNCTION public.list_vendor_filters() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_vendor_filters() TO authenticated;

-- Fix: avoid mixing aggregated and non-aggregated columns in same SELECT
CREATE OR REPLACE FUNCTION public.get_vendors_dashboard(
  p_user_id uuid,
  p_search text DEFAULT NULL,
  p_vendor_types text[] DEFAULT NULL,
  p_payment_methods text[] DEFAULT NULL,
  p_brands text[] DEFAULT NULL,
  p_regions text[] DEFAULT NULL,
  p_limit int DEFAULT 10,
  p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
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
    SELECT v.*
    FROM qvm_new_apps.vendors v
    WHERE (
      p_search IS NULL OR p_search = '' OR (
        v.vendor_name ILIKE '%'||p_search||'%'
        OR COALESCE(v.zoho_name,'') ILIKE '%'||p_search||'%'
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(COALESCE(v.brands,'[]'::jsonb)) b(val)
          WHERE val ILIKE '%'||p_search||'%'
        )
        OR EXISTS (
          SELECT 1 FROM jsonb_array_elements_text(COALESCE(v.region,'[]'::jsonb)) r(val)
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
          SELECT lower(btrim(x)) FROM regexp_split_to_table(COALESCE(v.payment_method,''), '\\s*,\\s*') x
        )
      )
    )
    AND (
      p_brands IS NULL OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(v.brands,'[]'::jsonb)) b(val)
        WHERE lower(btrim(val)) = ANY (SELECT lower(btrim(x)) FROM unnest(p_brands) x)
      )
    )
    AND (
      p_regions IS NULL OR EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(v.region,'[]'::jsonb)) r(val)
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
      v.region,
      v.operating_hours,
      v.brands,
      v.items_type,
      v.payment_method,
      v.tax_number,
      v.commercial_registeration_number,
      v.bank_name,
      v.bank_account,
      v.alternative_account,
      v.bank_and_cr_files
    FROM base v
    ORDER BY v.vendor_name NULLS LAST
    LIMIT GREATEST(p_limit, 1) OFFSET GREATEST(p_offset, 0)
  )
  SELECT c.c INTO v_total FROM cnt c;

  SELECT COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.vendor_name), '[]'::jsonb)
  INTO v_rows
  FROM paged p;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.get_vendors_dashboard(uuid, text, text[], text[], text[], text[], int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_vendors_dashboard(uuid, text, text[], text[], text[], text[], int, int) TO authenticated;

COMMIT;;
