-- Synced from QVM/test branch applied migration history (version 20260308134305, name: add_custom_access_token_hook_test_branch)
CREATE OR REPLACE FUNCTION public.custom_access_token_hook(event jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  claims jsonb;
  user_data jsonb;
BEGIN
  claims := event->'claims';
  user_data := qvm_new_apps.get_user_data((event->>'user_id')::uuid);

  IF user_data IS NULL THEN
    claims := jsonb_set(claims, '{user_data}', 'null'::jsonb, true);
  ELSE
    claims := jsonb_set(claims, '{user_data}', user_data, true);
  END IF;

  event := jsonb_set(event, '{claims}', claims, true);
  RETURN event;
END;
$function$;
;
