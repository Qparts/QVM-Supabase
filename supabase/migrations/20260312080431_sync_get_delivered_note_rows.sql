-- Synced from QVM/test branch applied migration history (version 20260312080431, name: sync_get_delivered_note_rows)
CREATE OR REPLACE FUNCTION public.get_delivered_note_rows(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 500)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  s text := coalesce(p_search, '');
  lim int := coalesce(p_limit, 500);
  dn_rows json;
  rn_rows json;
BEGIN
  SELECT coalesce(json_agg(t), '[]'::json) INTO dn_rows
  FROM (
    SELECT *
    FROM qvm_new_apps.delivery_notes dn
    WHERE (
      s = '' OR
      position(lower(s) in lower(coalesce(dn.order_number, ''))) > 0 OR
      position(lower(s) in lower(coalesce(dn.plate_number, ''))) > 0 OR
      position(lower(s) in lower(coalesce(dn.model, ''))) > 0
    )
    ORDER BY dn.created_at DESC
    LIMIT lim
  ) t;

  SELECT coalesce(json_agg(t), '[]'::json) INTO rn_rows
  FROM (
    SELECT *
    FROM qvm_new_apps.return_notes rn
    WHERE (
      s = '' OR
      position(lower(s) in lower(coalesce(rn.order_number, ''))) > 0 OR
      position(lower(s) in lower(coalesce(rn.plate_number, ''))) > 0 OR
      position(lower(s) in lower(coalesce(rn.model, ''))) > 0
    )
    ORDER BY rn.created_at DESC
    LIMIT lim
  ) t;

  RETURN json_build_object('dn', coalesce(dn_rows, '[]'::json), 'rn', coalesce(rn_rows, '[]'::json));
END;
$function$;
;
