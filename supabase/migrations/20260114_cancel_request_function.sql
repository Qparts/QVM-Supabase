-- Create function for handling cancellation requests
-- This function updates confirmed_items table and adds status logs entry

CREATE OR REPLACE FUNCTION qvm_new_apps.process_cancellation_request(
    p_confirmed_item_id integer,
    p_cancellation_reason_id integer,
    p_user_id uuid DEFAULT auth.uid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_result jsonb;
    v_old_status integer;
    v_new_status integer := 24; -- Cancellation Request status
    v_order_id integer;
    v_quotation_id integer;
BEGIN
    -- Validate inputs
    IF p_confirmed_item_id IS NULL OR p_cancellation_reason_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'Invalid input parameters');
    END IF;
    
    -- Check if confirmed item exists and get current status
    SELECT ci.item_status, co.confirmed_order_id, q.quotation_id
    INTO v_old_status, v_order_id, v_quotation_id
    FROM qvm_new_apps.confirmed_items ci
    JOIN qvm_new_apps.confirmed_orders co ON ci.confirmed_order_id = co.confirmed_order_id
    JOIN qvm_new_apps.quotations q ON co.quotation_id = q.quotation_id
    WHERE ci.confirmed_item_id = p_confirmed_item_id;
    
    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Confirmed item not found');
    END IF;
    
    -- Update the confirmed_items table
    UPDATE qvm_new_apps.confirmed_items
    SET 
        item_status = v_new_status,
        cancellation_reason = p_cancellation_reason_id,
        updated_at = now()
    WHERE confirmed_item_id = p_confirmed_item_id;
    
    -- Add status logs entry
    INSERT INTO qvm_new_apps.status_logs (
        confirmed_item_id,
        item_status,
        status_changed_by,
        created_at
    ) VALUES (
        p_confirmed_item_id,
        v_new_status,
        p_user_id,
        now()
    );
    
    -- Return success with updated data
    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'confirmed_item_id', p_confirmed_item_id,
            'old_status', v_old_status,
            'new_status', v_new_status,
            'cancellation_reason', p_cancellation_reason_id,
            'order_id', v_order_id,
            'quotation_id', v_quotation_id,
            'changed_by', p_user_id,
            'changed_at', now()
        )
    );
END;
$$;

-- Grant permissions
REVOKE EXECUTE ON FUNCTION qvm_new_apps.process_cancellation_request(integer, integer, uuid) FROM public, anon;
GRANT EXECUTE ON FUNCTION qvm_new_apps.process_cancellation_request(integer, integer, uuid) TO authenticated;
