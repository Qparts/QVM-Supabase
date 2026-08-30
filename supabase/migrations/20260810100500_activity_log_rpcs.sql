-- QNEW-100 Phase 1 RPCs. get_unseen_activity_count relies on activity_log's own RLS
-- (owner_user_id = auth.uid()) to naturally scope to what the caller owns — a record they don't
-- own simply contributes 0 rows, no separate authorization branch needed.
CREATE FUNCTION qvm_new_apps.get_unseen_activity_count(p_record_type text, p_record_id bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT count(*)::integer
  FROM qvm_new_apps.activity_log a
  WHERE a.record_type = p_record_type
    AND a.record_id = p_record_id
    AND a.owner_user_id = auth.uid()
    AND a.actor_user_id IS DISTINCT FROM auth.uid()
    AND a.created_at > COALESCE(
      (SELECT rv.last_viewed_at FROM qvm_new_apps.record_views rv
       WHERE rv.user_id = auth.uid() AND rv.record_type = p_record_type AND rv.record_id = p_record_id),
      '-infinity'::timestamptz
    );
$function$;

-- One aggregate per sidebar nav section for the caller: quotation_items/quotation_vendor_items/
-- quotation_vendors activity (RFQ/tendering-stage) buckets under "rfqs"; confirmed_items activity
-- (post-confirmation) buckets under "orders".
CREATE FUNCTION qvm_new_apps.get_unseen_activity_summary()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object(
    'rfqs', COALESCE(sum(CASE WHEN a.source_table IN ('quotation_items', 'quotation_vendor_items', 'quotation_vendors') THEN 1 ELSE 0 END), 0),
    'orders', COALESCE(sum(CASE WHEN a.source_table = 'confirmed_items' THEN 1 ELSE 0 END), 0)
  )
  FROM qvm_new_apps.activity_log a
  WHERE a.owner_user_id = auth.uid()
    AND a.actor_user_id IS DISTINCT FROM auth.uid()
    AND a.created_at > COALESCE(
      (SELECT rv.last_viewed_at FROM qvm_new_apps.record_views rv
       WHERE rv.user_id = auth.uid() AND rv.record_type = a.record_type AND rv.record_id = a.record_id),
      '-infinity'::timestamptz
    );
$function$;

-- "Compare & Price"/"Open & Purchase" button count: how many DISTINCT items on this order have
-- been priced (added or edited) by a vendor since this order was last opened — a meaningful,
-- actionable number ("3 items need review"), not a raw event count (which would over-count if a
-- vendor edited the same item's price more than once).
CREATE FUNCTION qvm_new_apps.get_unseen_priced_items_count(p_quotation_id bigint)
 RETURNS integer
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT count(DISTINCT a.quotation_item_id)::integer
  FROM qvm_new_apps.activity_log a
  WHERE a.record_type = 'order'
    AND a.record_id = p_quotation_id
    AND a.action IN ('price_added', 'price_edited')
    AND a.quotation_item_id IS NOT NULL
    AND a.owner_user_id = auth.uid()
    AND a.actor_user_id IS DISTINCT FROM auth.uid()
    AND a.created_at > COALESCE(
      (SELECT rv.last_viewed_at FROM qvm_new_apps.record_views rv
       WHERE rv.user_id = auth.uid() AND rv.record_type = 'order' AND rv.record_id = p_quotation_id),
      '-infinity'::timestamptz
    );
$function$;

-- Bulk variant of get_unseen_priced_items_count for table views (InternalOrdersTable) showing many
-- orders at once — one round trip instead of one RPC call per visible row, same convention as the
-- existing get_orders_pricing_progress(p_quotation_ids) used for that table's other per-order counts.
-- Only returns rows that actually have a nonzero count (callers default missing ids to 0).
CREATE FUNCTION qvm_new_apps.get_unseen_priced_items_counts(p_quotation_ids bigint[])
 RETURNS TABLE(quotation_id bigint, unseen_priced_count integer)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT a.record_id AS quotation_id, count(DISTINCT a.quotation_item_id)::integer AS unseen_priced_count
  FROM qvm_new_apps.activity_log a
  WHERE a.record_type = 'order'
    AND a.record_id = ANY(p_quotation_ids)
    AND a.action IN ('price_added', 'price_edited')
    AND a.quotation_item_id IS NOT NULL
    AND a.owner_user_id = auth.uid()
    AND a.actor_user_id IS DISTINCT FROM auth.uid()
    AND a.created_at > COALESCE(
      (SELECT rv.last_viewed_at FROM qvm_new_apps.record_views rv
       WHERE rv.user_id = auth.uid() AND rv.record_type = 'order' AND rv.record_id = a.record_id),
      '-infinity'::timestamptz
    )
  GROUP BY a.record_id;
$function$;

-- Bulk, generic version of get_unseen_activity_count for table views (RFQsListView) showing many
-- records at once — one round trip, same convention as get_unseen_priced_items_counts. Raw event
-- count (not distinct-items — that distinction only matters for the pricing-specific button).
CREATE FUNCTION qvm_new_apps.get_unseen_activity_counts(p_record_type text, p_record_ids bigint[])
 RETURNS TABLE(record_id bigint, unseen_count integer)
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT a.record_id, count(*)::integer AS unseen_count
  FROM qvm_new_apps.activity_log a
  WHERE a.record_type = p_record_type
    AND a.record_id = ANY(p_record_ids)
    AND a.owner_user_id = auth.uid()
    AND a.actor_user_id IS DISTINCT FROM auth.uid()
    AND a.created_at > COALESCE(
      (SELECT rv.last_viewed_at FROM qvm_new_apps.record_views rv
       WHERE rv.user_id = auth.uid() AND rv.record_type = p_record_type AND rv.record_id = a.record_id),
      '-infinity'::timestamptz
    )
  GROUP BY a.record_id;
$function$;

CREATE FUNCTION qvm_new_apps.mark_record_viewed(p_record_type text, p_record_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN;
  END IF;
  INSERT INTO qvm_new_apps.record_views (user_id, record_type, record_id, last_viewed_at)
  VALUES (auth.uid(), p_record_type, p_record_id, now())
  ON CONFLICT (user_id, record_type, record_id) DO UPDATE SET last_viewed_at = now();
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.get_unseen_activity_count(text, bigint) FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.get_unseen_activity_counts(text, bigint[]) FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.get_unseen_activity_summary() FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.get_unseen_priced_items_count(bigint) FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.get_unseen_priced_items_counts(bigint[]) FROM public, anon;
REVOKE ALL ON FUNCTION qvm_new_apps.mark_record_viewed(text, bigint) FROM public, anon;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_unseen_activity_count(text, bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_unseen_activity_counts(text, bigint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_unseen_activity_summary() TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_unseen_priced_items_count(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_unseen_priced_items_counts(bigint[]) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.mark_record_viewed(text, bigint) TO authenticated;
