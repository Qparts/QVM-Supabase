-- QPD-421: Fix conflict target to use column list instead of constraint name
BEGIN;

CREATE OR REPLACE FUNCTION public.upsert_purchase_order_items(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_confirmed_item_ids int[],
  p_mode text DEFAULT 'add',
  p_uploaded_source text DEFAULT 'internal'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_purchase_order_id bigint;
  v_inserted int := 0;
  v_deleted int := 0;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  SELECT purchase_order_id INTO v_purchase_order_id
  FROM purchase_orders
  WHERE confirmed_order_id = p_confirmed_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_purchase_order_id IS NULL THEN
    INSERT INTO purchase_orders(confirmed_order_id, uploaded_by, uploaded_at, uploaded_source)
    VALUES (p_confirmed_order_id, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
    RETURNING purchase_order_id INTO v_purchase_order_id;
  END IF;

  IF COALESCE(p_mode,'add') = 'replace' THEN
    DELETE FROM purchase_items
    WHERE purchase_order_id = v_purchase_order_id
      AND (p_confirmed_item_ids IS NULL OR confirmed_item_id <> ALL(p_confirmed_item_ids));
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
  END IF;

  IF COALESCE(array_length(p_confirmed_item_ids,1),0) > 0 THEN
    INSERT INTO purchase_items(confirmed_item_id, purchase_order_id)
    SELECT DISTINCT cid, v_purchase_order_id
    FROM unnest(p_confirmed_item_ids) AS cid
    ON CONFLICT (purchase_order_id, confirmed_item_id) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'status','success',
    'message','Purchase order items upserted',
    'purchase_order_id', v_purchase_order_id,
    'inserted', v_inserted,
    'deleted', v_deleted
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.upsert_purchase_order_items(uuid, int, int[], text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.upsert_purchase_order_items(uuid, int, int[], text, text) TO authenticated;

COMMIT;
