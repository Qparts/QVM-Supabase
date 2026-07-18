-- Create public wrapper function for cancellation requests
-- This provides a secure public interface to the qvm_new_apps.process_cancellation_request function

CREATE OR REPLACE FUNCTION public.process_cancellation_request(
    p_confirmed_item_id integer,
    p_cancellation_reason_id integer,
    p_user_id uuid DEFAULT auth.uid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    -- Validate input parameters first
    IF p_confirmed_item_id IS NULL OR p_cancellation_reason_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid input parameters');
    END IF;
    
    -- Validate that the user is authenticated
    IF p_user_id IS NULL OR auth.uid() IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Authentication required');
    END IF;
    
    -- Call the internal function with proper permissions
    RETURN qvm_new_apps.process_cancellation_request(
        p_confirmed_item_id,
        p_cancellation_reason_id,
        p_user_id
    );
END;
$$;

-- Grant permissions to authenticated users
REVOKE EXECUTE ON FUNCTION public.process_cancellation_request(integer, integer, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.process_cancellation_request(integer, integer, uuid) TO authenticated;
