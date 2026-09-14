-- The customers list stops creating a table to hold a list of ids.
--
--   0A000  CREATE TABLE is not allowed in a non-volatile function
--
-- The function is STABLE, which is correct — it reads and returns, it changes nothing — and a
-- STABLE function may not create even a temporary table. I reached for one because the set of
-- reachable customers is needed three times: for the total, for the per-kind counts, and for the
-- page of rows, and can_admin_end_customer is not something to evaluate three times over every
-- customer on the platform.
--
-- An array does the same job and costs nothing: the ids are gathered once, and the three queries
-- that follow filter on = ANY(...). The permission check still runs once per customer, which is the
-- part worth not repeating.

CREATE OR REPLACE FUNCTION qvm_new_apps.end_customers_list(
  p_search text    DEFAULT NULL,
  p_kind   text    DEFAULT NULL,
  p_limit  integer DEFAULT 200,
  p_offset integer DEFAULT 0
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_q text := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_ids bigint[];
  v_rows jsonb;
  v_counts jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  SELECT array_agg(c.end_customer_id) INTO v_ids
    FROM qvm_new_apps.end_customers c
   WHERE qvm_new_apps.can_admin_end_customer(c.end_customer_id)
     AND (v_q IS NULL
          OR COALESCE(
               (SELECT vc.name FROM qvm_new_apps.v_end_customers vc
                 WHERE vc.end_customer_id = c.end_customer_id), '') ILIKE '%' || v_q || '%'
          OR c.customer_code  ILIKE '%' || v_q || '%'
          OR c.phone          ILIKE '%' || v_q || '%'
          OR c.email          ILIKE '%' || v_q || '%'
          OR c.contact_person ILIKE '%' || v_q || '%')
     AND (p_kind IS NULL OR c.customer_kind = p_kind);

  v_ids := COALESCE(v_ids, ARRAY[]::bigint[]);

  SELECT jsonb_object_agg(k.customer_kind, k.n) INTO v_counts
  FROM (SELECT c.customer_kind, count(*) AS n
          FROM qvm_new_apps.end_customers c
         WHERE c.end_customer_id = ANY(v_ids)
         GROUP BY c.customer_kind) k;

  SELECT COALESCE(jsonb_agg(x ORDER BY x.display_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT vc.end_customer_id, vc.name AS display_name, vc.customer_kind, vc.customer_code,
           vc.tax_number, vc.contact_person, vc.phone, vc.email, vc.is_active,
           vc.branch_count, vc.user_count,
           (SELECT count(*) FROM qvm_new_apps.end_customer_branches b
              JOIN qvm_new_apps.end_customer_addresses a
                ON a.end_customer_branch_id = b.end_customer_branch_id AND a.is_active
             WHERE b.end_customer_id = vc.end_customer_id)::int AS address_count,
           COALESCE((
             SELECT jsonb_agg(jsonb_build_object('owner_kind', o.kind, 'display_name', o.name)
                              ORDER BY o.kind, o.name)
               FROM (
                 SELECT 'workshop'::text AS kind, vw.name
                   FROM qvm_new_apps.end_customer_owners eo
                   JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = eo.workshop_id
                  WHERE eo.end_customer_id = vc.end_customer_id AND eo.workshop_id IS NOT NULL
                 UNION ALL
                 SELECT 'vendor', vv.name
                   FROM qvm_new_apps.end_customer_owners eo
                   JOIN qvm_new_apps.v_vendors vv ON vv.vendor_id = eo.vendor_id
                  WHERE eo.end_customer_id = vc.end_customer_id AND eo.vendor_id IS NOT NULL
               ) o), '[]'::jsonb) AS owners
    FROM qvm_new_apps.v_end_customers vc
   WHERE vc.end_customer_id = ANY(v_ids)
    ORDER BY vc.name
    LIMIT GREATEST(COALESCE(p_limit, 200), 1)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  ) x;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'rows', v_rows,
    'total', COALESCE(array_length(v_ids, 1), 0),
    'counts', COALESCE(v_counts, '{}'::jsonb)));
END $$;
