-- Removing an AI report asks the admin gate as it exists.
--
-- delete_ai_report let the report's creator or a Qparts Admin remove it, and asked
-- is_qparts_admin(auth.uid()); on QVM/test that function takes no argument, so the button failed
-- with «function is_qparts_admin(uuid) does not exist». Called with no argument it works on every
-- environment (where the parameter exists it defaults to auth.uid()).

CREATE OR REPLACE FUNCTION qvm_new_apps.delete_ai_report(p_report_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v_company integer := qvm_new_apps.ai_caller_company();
BEGIN
  UPDATE qvm_new_apps.ai_reports SET deleted_at = now(), updated_by = auth.uid()
   WHERE report_id = p_report_id AND company_id = v_company AND deleted_at IS NULL
     AND (created_by = auth.uid() OR qvm_new_apps.is_qparts_admin());
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown report, or not yours to remove'; END IF;
  RETURN jsonb_build_object('status', 'success');
END $function$;
