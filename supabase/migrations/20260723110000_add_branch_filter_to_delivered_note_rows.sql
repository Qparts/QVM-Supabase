-- Adds a nullable p_branch_id filter to get_delivered_note_rows so the Delivered Orders page's
-- internal-user branch selector can actually scope its data - today this function has no branch
-- awareness at all (list_delivered_notes edge function calls it with only p_search/p_limit).
-- Omitting p_branch_id (or passing NULL) preserves today's behavior exactly - every branch.
--
-- delivery_notes/return_notes don't carry a numeric branch id directly (only a denormalized
-- "branch" text column), so the filter joins through confirmed_item_id -> quotation_items to
-- reach qvm_new_apps.client_branches.customer_id, matching the join used by
-- get_archive_note_rows for the same tables.
--
-- Adding a trailing parameter is a new overload in Postgres, not a REPLACE of the old one, so
-- the old-arity function is dropped first (same fix as
-- 20260625021131_drop_duplicate_get_internal_dashboard_text_overload.sql).

DROP FUNCTION IF EXISTS public.get_delivered_note_rows(text, integer);

CREATE FUNCTION public.get_delivered_note_rows(p_search text DEFAULT NULL::text, p_limit integer DEFAULT 500, p_branch_id integer DEFAULT NULL::integer)
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
    SELECT dn.*
    FROM qvm_new_apps.delivery_notes dn
    LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = dn.confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    WHERE (
      s = '' OR
      position(lower(s) in lower(coalesce(dn.order_number, ''))) > 0 OR
      position(lower(s) in lower(coalesce(dn.plate_number, ''))) > 0 OR
      position(lower(s) in lower(coalesce(dn.model, ''))) > 0
    )
    AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
    ORDER BY dn.created_at DESC
    LIMIT lim
  ) t;

  SELECT coalesce(json_agg(t), '[]'::json) INTO rn_rows
  FROM (
    SELECT rn.*
    FROM qvm_new_apps.return_notes rn
    LEFT JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = rn.confirmed_item_id
    LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    WHERE (
      s = '' OR
      position(lower(s) in lower(coalesce(rn.order_number, ''))) > 0 OR
      position(lower(s) in lower(coalesce(rn.plate_number, ''))) > 0 OR
      position(lower(s) in lower(coalesce(rn.model, ''))) > 0
    )
    AND (p_branch_id IS NULL OR qi.customer_id = p_branch_id)
    ORDER BY rn.created_at DESC
    LIMIT lim
  ) t;

  RETURN json_build_object('dn', coalesce(dn_rows, '[]'::json), 'rn', coalesce(rn_rows, '[]'::json));
END;
$function$
;

REVOKE EXECUTE ON FUNCTION public.get_delivered_note_rows(text, integer, integer) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_delivered_note_rows(text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_delivered_note_rows(text, integer, integer) TO service_role;

NOTIFY pgrst, 'reload schema';
