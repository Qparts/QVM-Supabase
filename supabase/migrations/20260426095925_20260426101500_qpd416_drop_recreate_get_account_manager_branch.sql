-- Synced from QVM/test branch applied migration history (version 20260426095925, name: 20260426101500_qpd416_drop_recreate_get_account_manager_branch)
BEGIN;

-- QPD-416: Drop and recreate with new return type to avoid 42P13
DROP FUNCTION IF EXISTS public.get_account_manager_branch(bigint, integer);

CREATE FUNCTION public.get_account_manager_branch(
  p_customer_id bigint,
  p_slot_number integer
)
RETURNS TABLE(
  main_account_manager uuid,
  first_substitute uuid,
  second_substitute uuid,
  fallback_account_manager uuid
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT 
    amb.main_account_manager,
    amb.first_substitute,
    amb.second_substitute,
    amb.fallback_account_manager
  FROM qvm_new_apps.account_manager_branches amb
  WHERE amb.customer_id = p_customer_id
    AND amb.slot_number = p_slot_number
  LIMIT 1;
END;
$$;

-- Grants
REVOKE ALL ON FUNCTION public.get_account_manager_branch(bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_account_manager_branch(bigint, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_account_manager_branch(bigint, integer) TO service_role;

COMMIT;
;
