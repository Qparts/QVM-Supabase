-- Create RPCs in public schema to fetch service advisor email from qvm_new_apps
-- This avoids requiring qvm_new_apps to be exposed to PostgREST

-- public.get_service_advisor_email_by_order(p_order_number text) -> text
CREATE OR REPLACE FUNCTION public.get_service_advisor_email_by_order(p_order_number text)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_email text;
BEGIN
  SELECT ud.email INTO v_email
  FROM qvm_new_apps.quotations q
  JOIN qvm_new_apps.user_data ud ON ud.user_id = q.service_advisor
  WHERE q.order_number = p_order_number
  LIMIT 1;
  RETURN v_email;
END;
$$;

-- public.get_service_advisor_email_by_confirmed_order(p_confirmed_order_id bigint) -> text
CREATE OR REPLACE FUNCTION public.get_service_advisor_email_by_confirmed_order(p_confirmed_order_id bigint)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_email text;
BEGIN
  SELECT ud.email INTO v_email
  FROM qvm_new_apps.confirmed_orders co
  JOIN qvm_new_apps.quotations q ON q.quotation_id = co.quotation_id
  JOIN qvm_new_apps.user_data ud ON ud.user_id = q.service_advisor
  WHERE co.confirmed_order_id = p_confirmed_order_id
  LIMIT 1;
  RETURN v_email;
END;
$$;

-- Optional: grant execute to common roles (Edge Functions use service_role)
GRANT EXECUTE ON FUNCTION public.get_service_advisor_email_by_order(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_service_advisor_email_by_confirmed_order(bigint) TO anon, authenticated, service_role;
