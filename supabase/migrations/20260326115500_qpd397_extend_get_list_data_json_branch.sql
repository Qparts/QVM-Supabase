-- QPD-397: Extend get_list_data_json to support branches from client_branches
SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.get_list_data_json(p_list_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    result_data jsonb;
BEGIN
    IF p_list_name = 'branch' THEN
        SELECT jsonb_agg(
            jsonb_build_object(
                'list_data_id', cb.customer_id,
                'list_data_name', cb.branch_name
            )
            ORDER BY cb.branch_name
        )
        INTO result_data
        FROM (
            SELECT DISTINCT customer_id, branch_name
            FROM qvm_new_apps.client_branches
            WHERE branch_name IS NOT NULL AND branch_name <> ''
        ) cb;
    ELSE
        SELECT jsonb_agg(
            jsonb_build_object(
                'list_data_id', ld.list_data_id,
                'list_data_name', ld.list_data
            )
            ORDER BY ld.list_data
        )
        INTO result_data
        FROM qvm_new_apps.list_data ld
        JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
        WHERE l.list_name = p_list_name;
    END IF;

    RETURN jsonb_build_object(
        'status', true,
        'message', p_list_name || ' list retrieved',
        'data', COALESCE(result_data, '[]'::jsonb)
    );
EXCEPTION
    WHEN OTHERS THEN
        RETURN jsonb_build_object(
            'status', false,
            'message', 'Error retrieving ' || p_list_name || ': ' || SQLERRM,
            'data', '[]'::jsonb
        );
END;
$function$;
