-- The names people read come from the localized views.
--
-- Switching language changed the labels around the data but not the data itself, because the RPCs
-- that produce company and branch names still read the untranslated columns. These are the three
-- that feed the pickers and the scope switcher — the places a name is chosen from — so they are the
-- ones that had to move first.
--
-- Each falls back to the old column when a record has no description yet, so nothing goes blank
-- while translations are still being filled in.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_clients()
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    result json;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Unauthorized';
    END IF;

    SELECT json_build_object(
        'status', true,
        'message', 'client list retrieved',
        'data', COALESCE(
            json_agg(
                json_build_object(
                    'client_id', ld.list_data_id,
                    -- The localized name when the company has one, the old list text when it does
                    -- not: a company added before the tier existed still has to have a name.
                    'client_name', COALESCE(vc.name, ld.list_data)
                )
                ORDER BY COALESCE(vc.name, ld.list_data)
            ),
            '[]'::json
        )
    )
    INTO result
    FROM qvm_new_apps.list_data ld
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
    LEFT JOIN qvm_new_apps.v_client_companies vc ON vc.company_id = ld.list_data_id
    WHERE l.list_name = 'client_name'
      AND EXISTS (
          SELECT 1 FROM qvm_new_apps.order_number_sequences ons
          WHERE ons.lists_data_id = ld.list_data_id
      );

    RETURN result;
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_client_branch(p_customer_id integer)
 RETURNS json
 LANGUAGE plpgsql
AS $function$declare
    result json;
begin
    -- Enforce authentication
    if auth.uid() is null then
        raise exception 'Unauthorized';
    end if;

    -- Fetch branch data where list_data_id = p_customer_id
    select json_build_object(
        'status', true,
        'message', 'branch data retrieved',
        'data', coalesce(
            json_agg(row_to_json(b)),
            '[]'::json
        )
    )
    into result
    from (
        -- Every column the callers already read, with branch_name replaced by the name in the
        -- reader's language. Replaced rather than added: the field the UI binds to is branch_name,
        -- and a second key would have meant touching every caller.
        select cb.customer_id, cb.list_data_id, vb.name as branch_name, cb.created_at, cb.updated_at,
               cb.region_id, cb.order_category, cb.zoho_id, cb.is_bulk_client,
               cb.city, cb.city_id, cb.location_lat, cb.location_lng, cb.workshop_id
        from qvm_new_apps.client_branches cb
        join qvm_new_apps.v_client_branches vb on vb.customer_id = cb.customer_id
        where cb.list_data_id = p_customer_id
    ) b;

    return result;
end;$function$;

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
            -- v_client_branches resolves the name in the reader's language and falls back to the
            -- old branch_name column, so a branch never loses its label.
            SELECT DISTINCT vb.customer_id, vb.name AS branch_name
            FROM qvm_new_apps.v_client_branches vb
            WHERE COALESCE(vb.name, '') <> ''
              AND (v_branch_scope IS NULL OR vb.customer_id = ANY(v_branch_scope))
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
