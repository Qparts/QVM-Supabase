-- Every customer the caller can reach, as a flat list.
--
-- The tree is for placing a customer — which vendor, which workshop, which branch. This is for
-- finding one: a search box over every customer at once, which is what somebody with a name and a
-- phone number in front of them actually needs.
--
-- Reach is the same question the tree asks, asked once per row: a Qparts Admin sees everything, and
-- anyone else sees the customers of the workshops and vendors their companies deal with.

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
  v_rows jsonb;
  v_total int;
  v_counts jsonb;
BEGIN
  IF NOT (qvm_new_apps.is_qparts_admin(v_uid) OR qvm_new_apps.is_company_admin(v_uid)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: administrators only');
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _reachable (end_customer_id bigint PRIMARY KEY) ON COMMIT DROP;
  DELETE FROM _reachable;
  INSERT INTO _reachable (end_customer_id)
  SELECT c.end_customer_id
    FROM qvm_new_apps.end_customers c
   WHERE qvm_new_apps.can_admin_end_customer(c.end_customer_id)
     AND (v_q IS NULL
          OR COALESCE(
               (SELECT vc.name FROM qvm_new_apps.v_end_customers vc
                 WHERE vc.end_customer_id = c.end_customer_id), '') ILIKE '%' || v_q || '%'
          OR c.customer_code ILIKE '%' || v_q || '%'
          OR c.phone ILIKE '%' || v_q || '%'
          OR c.email ILIKE '%' || v_q || '%'
          OR c.contact_person ILIKE '%' || v_q || '%')
     AND (p_kind IS NULL OR c.customer_kind = p_kind);

  SELECT count(*) INTO v_total FROM _reachable;

  -- The four kinds with a number beside each, over the same reach and the same search, so the
  -- chips agree with the list rather than counting something else.
  SELECT jsonb_object_agg(k.customer_kind, k.n) INTO v_counts
  FROM (SELECT c.customer_kind, count(*) AS n
          FROM qvm_new_apps.end_customers c
          JOIN _reachable r ON r.end_customer_id = c.end_customer_id
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
           -- Who deals with them. A customer often belongs to one workshop and one vendor, and the
           -- list is the only place that shows both without clicking through the tree.
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
    JOIN _reachable r ON r.end_customer_id = vc.end_customer_id
    ORDER BY vc.name
    LIMIT GREATEST(COALESCE(p_limit, 200), 1)
    OFFSET GREATEST(COALESCE(p_offset, 0), 0)
  ) x;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'rows', v_rows,
    'total', v_total,
    'counts', COALESCE(v_counts, '{}'::jsonb)));
END $$;

CREATE OR REPLACE FUNCTION public.end_customers_list(
  p_search text DEFAULT NULL, p_kind text DEFAULT NULL,
  p_limit integer DEFAULT 200, p_offset integer DEFAULT 0) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.end_customers_list(p_search, p_kind, p_limit, p_offset) $$;

REVOKE ALL ON FUNCTION public.end_customers_list(text, text, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.end_customers_list(text, text, integer, integer) TO authenticated;
