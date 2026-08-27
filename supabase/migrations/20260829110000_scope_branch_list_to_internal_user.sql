-- The internal dashboard's header branch switcher (InternalBranchSwitcher.tsx) calls
-- get_list_data_json('branch'), which returns every client_branches row system-wide with no
-- scoping at all. A branch-scoped internal sub-user should only see the branches actually
-- assigned to them there — same source of truth as get_internal_branch_scope (NULL for
-- Qparts Admin = unrestricted, unchanged; otherwise exactly their assigned branch ids).
CREATE OR REPLACE FUNCTION public.get_list_data_json(p_list_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
DECLARE
    result_data jsonb;
    v_branch_scope integer[];
BEGIN
    IF p_list_name = 'branch' THEN
        v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

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
              AND (v_branch_scope IS NULL OR customer_id = ANY(v_branch_scope))
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
