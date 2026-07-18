CREATE OR REPLACE FUNCTION qvm_new_apps.get_account_manager_email(p_quotation_id integer)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$DECLARE
    v_email TEXT;
BEGIN
    SELECT u.email
    INTO v_email
    FROM qvm_new_apps.quotations q
    JOIN qvm_new_apps.user_data u ON u.user_id = q.account_manager
    WHERE q.quotation_id = p_quotation_id
    LIMIT 1;

    RETURN v_email;
END;$function$
;
