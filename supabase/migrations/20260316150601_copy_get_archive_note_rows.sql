-- Synced from QVM/test branch applied migration history (version 20260316150601, name: copy_get_archive_note_rows)
CREATE OR REPLACE FUNCTION public.get_archive_note_rows(p_search text DEFAULT NULL::text, p_type text DEFAULT 'all'::text, p_days integer DEFAULT 30)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  since_ts timestamptz;
  dn_rows json;
  rn_rows json;
  s text := coalesce(p_search, '');
  typ text := coalesce(p_type, 'all');
  dayz int := coalesce(p_days, 30);
BEGIN
  since_ts := now() - make_interval(days => dayz);

  IF typ <> 'rn' THEN
    SELECT coalesce(json_agg(t), '[]'::json) INTO dn_rows
    FROM (
      SELECT *
      FROM qvm_new_apps.delivery_notes dn
      WHERE (dn.invoice_number IS NOT NULL AND length(dn.invoice_number) > 0)
        AND dn.created_at >= since_ts
        AND (
          s = '' OR
          position(lower(s) in lower(coalesce(dn.order_number, ''))) > 0 OR
          position(lower(s) in lower(coalesce(dn.plate_number, ''))) > 0 OR
          position(lower(s) in lower(coalesce(dn.model, ''))) > 0
        )
    ) t;
  ELSE
    dn_rows := '[]'::json;
  END IF;

  IF typ <> 'dn' THEN
    SELECT coalesce(json_agg(t), '[]'::json) INTO rn_rows
    FROM (
      SELECT *
      FROM qvm_new_apps.return_notes rn
      WHERE (rn.creditnote_number IS NOT NULL AND length(rn.creditnote_number) > 0)
        AND rn.created_at >= since_ts
        AND (
          s = '' OR
          position(lower(s) in lower(coalesce(rn.order_number, ''))) > 0 OR
          position(lower(s) in lower(coalesce(rn.plate_number, ''))) > 0 OR
          position(lower(s) in lower(coalesce(rn.model, ''))) > 0
        )
    ) t;
  ELSE
    rn_rows := '[]'::json;
  END IF;

  RETURN json_build_object('dn', coalesce(dn_rows, '[]'::json), 'rn', coalesce(rn_rows, '[]'::json));
END;
$function$;
;
