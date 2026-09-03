-- Fix: earlier research (grepping only tracked migration files) missed that
-- public.process_cancellation_request / public.process_return_request already existed live,
-- untracked, with a DIFFERENT signature (p_user_id) than what the frontend/new qvm_new_apps
-- versions use (p_notes / no p_user_id). PostgREST resolves supabase.rpc() calls against the
-- `public` schema by name+parameter-name match, so the frontend's calls were failing with
-- PGRST202 even though a same-named function existed. This drops the stale overloads and makes
-- `public` a thin wrapper over the already-correct qvm_new_apps versions, matching this
-- codebase's established public-wrapper convention everywhere else.

DROP FUNCTION IF EXISTS public.process_cancellation_request(integer, integer, uuid);
DROP FUNCTION IF EXISTS qvm_new_apps.process_cancellation_request(integer, integer, uuid);
DROP FUNCTION IF EXISTS public.process_return_request(integer, text, integer, integer, uuid, text);

CREATE OR REPLACE FUNCTION public.process_cancellation_request(
  p_confirmed_item_id integer,
  p_cancellation_reason_id integer,
  p_notes text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  RETURN qvm_new_apps.process_cancellation_request(p_confirmed_item_id, p_cancellation_reason_id, p_notes);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_cancellation_request(integer, integer, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.process_return_request(
  p_confirmed_item_id integer,
  p_return_type text,
  p_return_quantity integer,
  p_return_reason_id integer,
  p_additional_notes text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
BEGIN
  RETURN qvm_new_apps.process_return_request(p_confirmed_item_id, p_return_type, p_return_quantity, p_return_reason_id, p_additional_notes);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.process_return_request(integer, text, integer, integer, text) TO authenticated;

-- Same drift risk applies to the approve/reject/list RPCs: add public wrappers too, in case any
-- future caller uses the bare (schema-less) supabase.rpc() form instead of .schema('qvm_new_apps').
CREATE OR REPLACE FUNCTION public.approve_item_status_request(p_confirmed_item_id integer)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.approve_item_status_request(p_confirmed_item_id);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.approve_item_status_request(integer) TO authenticated;

CREATE OR REPLACE FUNCTION public.reject_item_status_request(p_confirmed_item_id integer, p_resolution_note text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.reject_item_status_request(p_confirmed_item_id, p_resolution_note);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.reject_item_status_request(integer, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.get_pending_item_status_requests(p_request_type text)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.get_pending_item_status_requests(p_request_type);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.get_pending_item_status_requests(text) TO authenticated;
