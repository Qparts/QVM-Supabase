-- The Account Managers module names branches the way the rest of the app does.
--
-- Its branches tab read client_branches.branch_name — the untranslated column — so an Arabic reader
-- saw English names there and nowhere else. It also showed the name alone, which stopped
-- identifying anything the moment workshops arrived: two workshops can each have a "Main Bay".
--
-- The tab itself already covers what it needs to: coverage per branch across the three slots, the
-- attendance behind it on the Slots tab, and the resulting allocation on Allocations. New branches
-- appear there on their own because it reads client_branches directly.

CREATE OR REPLACE FUNCTION public.get_account_manager_branches_dashboard(p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_can_edit boolean := false;
  v_rows jsonb := '[]'::jsonb;
BEGIN
  SELECT (
    EXISTS (
      SELECT 1
      FROM qvm_new_apps.user_data u
      LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
      WHERE u.user_id = p_user_id
        AND (
          u.user_type = 185
          OR lower(ur.list_data) IN ('admin','pricing supervisor')
        )
    )
  ) INTO v_can_edit;

  WITH pivot AS (
    SELECT
      cb.customer_id::int AS branch_id,
      -- The name in the reader's language, and the workshop it belongs to: with workshops, two
      -- branches can both be called "Main Bay" and the name alone stops identifying one.
      COALESCE(vb.name, cb.branch_name) || COALESCE(' · ' || vw.name, '') AS branch_name,
      CAST(MAX(CASE WHEN amb.slot_number = 1 THEN (amb.main_account_manager)::text END) AS uuid) AS main_s1,
      CAST(MAX(CASE WHEN amb.slot_number = 2 THEN (amb.main_account_manager)::text END) AS uuid) AS main_s2,
      CAST(MAX(CASE WHEN amb.slot_number = 3 THEN (amb.main_account_manager)::text END) AS uuid) AS main_s3,
      CAST(MAX(CASE WHEN amb.slot_number = 1 THEN (amb.first_substitute)::text END) AS uuid) AS sub1_s1,
      CAST(MAX(CASE WHEN amb.slot_number = 2 THEN (amb.first_substitute)::text END) AS uuid) AS sub1_s2,
      CAST(MAX(CASE WHEN amb.slot_number = 3 THEN (amb.first_substitute)::text END) AS uuid) AS sub1_s3,
      CAST(MAX(CASE WHEN amb.slot_number = 1 THEN (amb.second_substitute)::text END) AS uuid) AS sub2_s1,
      CAST(MAX(CASE WHEN amb.slot_number = 2 THEN (amb.second_substitute)::text END) AS uuid) AS sub2_s2,
      CAST(MAX(CASE WHEN amb.slot_number = 3 THEN (amb.second_substitute)::text END) AS uuid) AS sub2_s3,
      CAST(COALESCE(
        MAX(CASE WHEN amb.slot_number = 1 THEN (amb.fallback_account_manager)::text END),
        MAX(CASE WHEN amb.slot_number = 2 THEN (amb.fallback_account_manager)::text END),
        MAX(CASE WHEN amb.slot_number = 3 THEN (amb.fallback_account_manager)::text END)
      ) AS uuid) AS fallback_user
    FROM qvm_new_apps.client_branches cb
    LEFT JOIN qvm_new_apps.v_client_branches vb ON vb.customer_id = cb.customer_id
    LEFT JOIN qvm_new_apps.v_client_workshops vw ON vw.workshop_id = cb.workshop_id
    LEFT JOIN qvm_new_apps.account_manager_branches amb ON amb.customer_id = cb.customer_id::bigint
    GROUP BY cb.customer_id, vb.name, cb.branch_name, vw.name
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.branch_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      p.branch_id,
      p.branch_name,
      p.main_s1,
      um1.user_name AS main_s1_name,
      p.main_s2,
      um2.user_name AS main_s2_name,
      p.main_s3,
      um3.user_name AS main_s3_name,
      p.sub1_s1,
      u11.user_name AS sub1_s1_name,
      p.sub1_s2,
      u12.user_name AS sub1_s2_name,
      p.sub1_s3,
      u13.user_name AS sub1_s3_name,
      p.sub2_s1,
      u21.user_name AS sub2_s1_name,
      p.sub2_s2,
      u22.user_name AS sub2_s2_name,
      p.sub2_s3,
      u23.user_name AS sub2_s3_name,
      p.fallback_user,
      uf.user_name AS fallback_user_name
    FROM pivot p
    LEFT JOIN qvm_new_apps.user_data um1 ON um1.user_id = p.main_s1
    LEFT JOIN qvm_new_apps.user_data um2 ON um2.user_id = p.main_s2
    LEFT JOIN qvm_new_apps.user_data um3 ON um3.user_id = p.main_s3
    LEFT JOIN qvm_new_apps.user_data u11 ON u11.user_id = p.sub1_s1
    LEFT JOIN qvm_new_apps.user_data u12 ON u12.user_id = p.sub1_s2
    LEFT JOIN qvm_new_apps.user_data u13 ON u13.user_id = p.sub1_s3
    LEFT JOIN qvm_new_apps.user_data u21 ON u21.user_id = p.sub2_s1
    LEFT JOIN qvm_new_apps.user_data u22 ON u22.user_id = p.sub2_s2
    LEFT JOIN qvm_new_apps.user_data u23 ON u23.user_id = p.sub2_s3
    LEFT JOIN qvm_new_apps.user_data uf  ON uf.user_id  = p.fallback_user
  ) t;

  RETURN jsonb_build_object('can_edit', v_can_edit, 'rows', v_rows);
END;
$function$;
