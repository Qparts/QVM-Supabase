-- Synced from QVM/test branch applied migration history (version 20260713215141, name: upsert_purchase_order_items_optional_qty)
-- Additive, backward-compatible: add an optional p_item_qtys array so the smart-upload
-- flow can record how many units of each order line an invoice fulfils. When omitted (NULL)
-- the insert path is byte-identical to the previous behaviour (whole-item link, approved_qty NULL).
DROP FUNCTION IF EXISTS public.upsert_purchase_order_items(uuid, integer, integer[], text, text);

CREATE OR REPLACE FUNCTION public.upsert_purchase_order_items(
  p_user_id uuid,
  p_confirmed_order_id integer,
  p_confirmed_item_ids integer[],
  p_mode text DEFAULT 'add',
  p_uploaded_source text DEFAULT 'internal',
  p_item_qtys integer[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_user_type int;
  v_is_internal boolean;
  v_purchase_order_id bigint;
  v_inserted int := 0;
  v_deleted int := 0;
  v_use_qtys boolean := (p_item_qtys IS NOT NULL AND array_length(p_item_qtys,1) = array_length(p_confirmed_item_ids,1));
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  -- Always create a fresh purchase_order to isolate this upload per selection
  INSERT INTO purchase_orders(confirmed_order_id, uploaded_by, uploaded_at, uploaded_source)
  VALUES (p_confirmed_order_id, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
  RETURNING purchase_order_id INTO v_purchase_order_id;

  IF COALESCE(array_length(p_confirmed_item_ids,1),0) > 0 THEN
    IF v_use_qtys THEN
      -- Pair each item id with its allocated units (0 -> NULL, i.e. treat as whole item).
      INSERT INTO purchase_items(confirmed_item_id, purchase_order_id, approved_qty)
      SELECT cid, v_purchase_order_id, NULLIF(qty, 0)
      FROM unnest(p_confirmed_item_ids, p_item_qtys) AS u(cid, qty)
      ON CONFLICT (purchase_order_id, confirmed_item_id) DO NOTHING;
    ELSE
      INSERT INTO purchase_items(confirmed_item_id, purchase_order_id)
      SELECT DISTINCT cid, v_purchase_order_id
      FROM unnest(p_confirmed_item_ids) AS cid
      ON CONFLICT (purchase_order_id, confirmed_item_id) DO NOTHING;
    END IF;
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
$function$;;
