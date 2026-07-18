-- Synced from QVM/test branch applied migration history (version 20260426083933, name: 20260426094000_qpd414_add_get_client_branch)
BEGIN;

-- QPD-414: Ensure public.get_client_branch exists and works on TEST
-- Create/replace underlying implementation in qvm_new_apps
CREATE OR REPLACE FUNCTION qvm_new_apps.get_client_branch(
  p_customer_id integer
)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_branch RECORD;
BEGIN
  SELECT cb.customer_id,
         cb.branch_name,
         cb.region_id,
         cb.order_category,
         cb.list_data_id
  INTO v_branch
  FROM qvm_new_apps.client_branches cb
  WHERE cb.customer_id = p_customer_id
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN json_build_object(
      'status', false,
      'message', 'Branch not found',
      'data', NULL
    );
  END IF;

  RETURN json_build_object(
    'status', true,
    'message', 'Branch retrieved',
    'data', row_to_json(v_branch)
  );
END;
$$;

-- Public wrapper for PostgREST clients
CREATE OR REPLACE FUNCTION public.get_client_branch(
  p_customer_id integer
)
RETURNS json
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT qvm_new_apps.get_client_branch(p_customer_id);
$$;

-- Grants
GRANT EXECUTE ON FUNCTION public.get_client_branch(integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_client_branch(integer) TO service_role;

COMMIT;
;
