-- Synced from QVM/test branch applied migration history (version 20260406090320, name: qpd414_vendors_dashboard)
BEGIN;

SET search_path TO qvm_new_apps, public;

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
  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('id', initcap(trim(v.vendor_type)), 'name', initcap(trim(v.vendor_type))) ORDER BY initcap(trim(v.vendor_type))), '[]'::jsonb)
  INTO v_vendor_types
  FROM qvm_new_apps.vendors v
  WHERE v.vendor_type IS NOT NULL AND btrim(v.vendor_type) <> '';

  WITH pm AS (
    SELECT lower(btrim(x)) AS name
    FROM qvm_new_apps.vendors v, regexp_split_to_table(COALESCE(v.payment_method,''), '\\s*,\\s*') x
    WHERE x IS NOT NULL AND btrim(x) <> ''
  )
  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('id', initcap(name), 'name', initcap(name)) ORDER BY initcap(name)), '[]'::jsonb)
  INTO v_payment_methods
  FROM pm;

  WITH b AS (
    SELECT initcap(btrim(elem)) AS name
    FROM qvm_new_apps.vendors v, jsonb_array_elements_text(COALESCE(v.brands, '[]'::jsonb)) elem
    WHERE elem IS NOT NULL AND btrim(elem) <> ''
  )
  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_brands
  FROM b;

  WITH r AS (
    SELECT initcap(btrim(elem)) AS name
    FROM qvm_new_apps.vendors v, jsonb_array_elements_text(COALESCE(v.region, '[]'::jsonb)) elem
    WHERE elem IS NOT NULL AND btrim(elem) <> ''
  )
  SELECT COALESCE(jsonb_agg(DISTINCT jsonb_build_object('id', name, 'name', name) ORDER BY name), '[]'::jsonb)
  INTO v_regions
  FROM r;

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
  SELECT c.c, COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.vendor_name), '[]'::jsonb)
  INTO v_total, v_rows
  FROM cnt c, paged p;

  RETURN jsonb_build_object('total', v_total, 'rows', v_rows);
END;
$$;

REVOKE ALL ON FUNCTION public.get_vendors_dashboard(uuid, text, text[], text[], text[], text[], int, int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_vendors_dashboard(uuid, text, text[], text[], text[], text[], int, int) TO authenticated;

COMMIT;;
