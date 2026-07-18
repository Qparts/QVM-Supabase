-- Synced from QVM/test branch applied migration history (version 20260408092256, name: qpd453_fix_max_uuid_aggregate)
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.get_account_manager_allocations_dashboard(
  p_user_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
DECLARE
  v_allowed boolean := false;
  v_rows jsonb := '[]'::jsonb;
  v_last timestamptz := NULL;
BEGIN
  SELECT (
    EXISTS (
      SELECT 1 FROM qvm_new_apps.user_data u
      LEFT JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
      WHERE u.user_id = p_user_id AND (u.user_type = 185 OR lower(ur.list_data) IN ('qparts admin'))
    )
  ) INTO v_allowed;
  IF NOT v_allowed THEN
    RAISE EXCEPTION 'Unauthorized';
  END IF;

  SELECT MAX(calculated_at) INTO v_last FROM qvm_new_apps.account_manager_allocations;

  WITH a AS (
    SELECT * FROM qvm_new_apps.account_manager_allocations
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.branch_name), '[]'::jsonb) INTO v_rows
  FROM (
    SELECT
      cb.customer_id AS branch_id,
      cb.branch_name AS branch_name,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.saturday)::text END))::uuid  AS saturday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.saturday)::text END))::uuid  AS saturday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.saturday)::text END))::uuid  AS saturday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.sunday)::text END))::uuid    AS sunday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.sunday)::text END))::uuid    AS sunday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.sunday)::text END))::uuid    AS sunday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.monday)::text END))::uuid    AS monday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.monday)::text END))::uuid    AS monday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.monday)::text END))::uuid    AS monday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.tuesday)::text END))::uuid   AS tuesday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.tuesday)::text END))::uuid   AS tuesday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.tuesday)::text END))::uuid   AS tuesday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.wednesday)::text END))::uuid AS wednesday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.wednesday)::text END))::uuid AS wednesday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.wednesday)::text END))::uuid AS wednesday_s3,
      (MAX(CASE WHEN a.slot_number = 1 THEN (a.thursday)::text END))::uuid  AS thursday_s1,
      (MAX(CASE WHEN a.slot_number = 2 THEN (a.thursday)::text END))::uuid  AS thursday_s2,
      (MAX(CASE WHEN a.slot_number = 3 THEN (a.thursday)::text END))::uuid  AS thursday_s3
    FROM qvm_new_apps.client_branches cb
    LEFT JOIN a ON a.customer_id = cb.customer_id
    GROUP BY cb.customer_id, cb.branch_name
  ) x;

  RETURN jsonb_build_object('rows', v_rows, 'last_calculated_at', v_last);
END;
$$;

REVOKE ALL ON FUNCTION public.get_account_manager_allocations_dashboard(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_manager_allocations_dashboard(uuid) TO authenticated;

COMMIT;;
