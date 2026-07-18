CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_emails(p_vendor_ids integer[])
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
    v_emails JSON;
BEGIN
    SELECT json_agg(DISTINCT u.email)
    INTO v_emails
    FROM qvm_new_apps.vendors v
    JOIN qvm_new_apps.user_data u ON u.user_id = v.user_id
    WHERE v.vendor_id = ANY(p_vendor_ids)
      AND u.email IS NOT NULL
      AND u.email <> '';

    RETURN COALESCE(v_emails, '[]'::json);
END;$function$
;
