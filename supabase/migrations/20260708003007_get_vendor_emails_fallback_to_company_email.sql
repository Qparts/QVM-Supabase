-- Synced from QVM/test branch applied migration history (version 20260708003007, name: get_vendor_emails_fallback_to_company_email)
CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_emails(p_vendor_ids integer[], p_vendor_branch_id bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_emails JSON;
BEGIN
    SELECT json_agg(DISTINCT email) INTO v_emails
    FROM (
        SELECT u.email
        FROM qvm_new_apps.vendors v
        JOIN qvm_new_apps.user_data u ON u.user_id = v.user_id
        WHERE v.vendor_id = ANY(p_vendor_ids)
          AND u.email IS NOT NULL AND u.email <> ''

        UNION

        SELECT u.email
        FROM qvm_new_apps.user_data u
        JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
        WHERE u.user_vendor = ANY(p_vendor_ids)
          AND ur.list_data = 'Vendor Admin'
          AND u.email IS NOT NULL AND u.email <> ''

        UNION

        SELECT u.email
        FROM qvm_new_apps.user_data u
        WHERE u.user_vendor = ANY(p_vendor_ids)
          AND u.email IS NOT NULL AND u.email <> ''
          AND (
            p_vendor_branch_id IS NULL
            OR EXISTS (
              SELECT 1 FROM qvm_new_apps.vendor_branch_users vbu
              WHERE vbu.user_id = u.user_id AND vbu.vendor_branch_id = p_vendor_branch_id
            )
          )

        UNION

        SELECT v.email
        FROM qvm_new_apps.vendors v
        WHERE v.vendor_id = ANY(p_vendor_ids)
          AND v.email IS NOT NULL AND v.email <> ''
          AND NOT EXISTS (
            SELECT 1 FROM qvm_new_apps.user_data u3 WHERE u3.user_vendor = v.vendor_id AND u3.user_type = 205
          )
    ) e;

    RETURN COALESCE(v_emails, '[]'::json);
END;
$function$;
;
