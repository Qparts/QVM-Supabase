-- Synced from QVM/test branch applied migration history (version 20260325123215, name: qpd388_upload_invoice_rpcs_and_helpers)
-- QPD-388: RPCs for uploading purchase invoices and vendor credit notes + helper
SET search_path TO qvm_new_apps, public;

-- Helper to resolve confirmed_order_id from order number
CREATE OR REPLACE FUNCTION public.get_confirmed_order_id_by_order_number(
  p_order_number text
)
RETURNS int
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $$
  SELECT co.confirmed_order_id
  FROM quotations q
  JOIN confirmed_orders co ON co.quotation_id = q.quotation_id
  WHERE q.order_number = p_order_number
  ORDER BY co.created_at DESC
  LIMIT 1;
$$;

REVOKE EXECUTE ON FUNCTION public.get_confirmed_order_id_by_order_number(text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.get_confirmed_order_id_by_order_number(text) TO authenticated;

-- Upsert purchase invoice into purchase_orders
CREATE OR REPLACE FUNCTION public.upsert_purchase_invoice(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_vendor_invoice_url text,
  p_vendor_invoice_number text,
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
    INSERT INTO purchase_orders(confirmed_order_id, vendor_invoice_url, vendor_invoice_number, uploaded_by, uploaded_at, uploaded_source)
    VALUES (p_confirmed_order_id, p_vendor_invoice_url, p_vendor_invoice_number, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
    RETURNING purchase_order_id INTO v_purchase_order_id;
  ELSE
    UPDATE purchase_orders
    SET vendor_invoice_url = p_vendor_invoice_url,
        vendor_invoice_number = p_vendor_invoice_number,
        uploaded_by = p_user_id,
        uploaded_at = now(),
        uploaded_source = COALESCE(NULLIF(p_uploaded_source,''),'internal')
    WHERE purchase_order_id = v_purchase_order_id;
  END IF;

  RETURN jsonb_build_object('status','success','message','Purchase invoice saved','purchase_order_id', v_purchase_order_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.upsert_purchase_invoice(uuid, int, text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.upsert_purchase_invoice(uuid, int, text, text, text) TO authenticated;

-- Upsert vendor credit note linked to purchase order
CREATE OR REPLACE FUNCTION public.upsert_vendor_creditnote(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_vendor_creditnote_url text,
  p_vendor_creditnote_number text,
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
  v_vendor_creditnote_id bigint;
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

  SELECT vendor_creditnote_id INTO v_vendor_creditnote_id
  FROM vendor_creditnotes
  WHERE purchase_order_id = v_purchase_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF v_vendor_creditnote_id IS NULL THEN
    INSERT INTO vendor_creditnotes(purchase_order_id, vendor_creditnote_url, vendor_creditnote_number, uploaded_by, uploaded_at, uploaded_source)
    VALUES (v_purchase_order_id, p_vendor_creditnote_url, p_vendor_creditnote_number, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
    RETURNING vendor_creditnote_id INTO v_vendor_creditnote_id;
  ELSE
    UPDATE vendor_creditnotes
    SET vendor_creditnote_url = p_vendor_creditnote_url,
        vendor_creditnote_number = p_vendor_creditnote_number,
        uploaded_by = p_user_id,
        uploaded_at = now(),
        uploaded_source = COALESCE(NULLIF(p_uploaded_source,''),'internal')
    WHERE vendor_creditnote_id = v_vendor_creditnote_id;
  END IF;

  RETURN jsonb_build_object('status','success','message','Vendor credit note saved','vendor_creditnote_id', v_vendor_creditnote_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.upsert_vendor_creditnote(uuid, int, text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.upsert_vendor_creditnote(uuid, int, text, text, text) TO authenticated;;
