-- Create RPC function in public schema to get service advisors
-- This function returns service advisors based on user permissions

CREATE OR REPLACE FUNCTION public.get_service_advisors(
  p_user_id uuid,
  p_is_internal boolean DEFAULT false,
  p_user_branch int DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
  v_result jsonb;
BEGIN
  SELECT jsonb_build_object(
    'status', 'success',
    'message', 'Service advisors fetched successfully',
    'data', COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'user_id', u.user_id,
          'user_name', u.user_name,
          'user_branch', u.user_branch,
          'user_company', u.user_company
        )
        ORDER BY u.user_name
      ),
      '[]'::jsonb
    )
  )
  INTO v_result
  FROM qvm_new_apps.user_data u
  WHERE u.user_role IN (170, 171)  -- Service advisors only
    AND (
      p_is_internal 
      OR u.user_branch = p_user_branch  -- Only advisors from user's branch
    );

  RETURN v_result;
END;
$function$;

-- Grant permissions
REVOKE EXECUTE ON FUNCTION public.get_service_advisors(uuid, boolean, int) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_service_advisors(uuid, boolean, int) TO authenticated;
