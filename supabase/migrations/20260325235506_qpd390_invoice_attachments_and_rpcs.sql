-- Synced from QVM/test branch applied migration history (version 20260325235506, name: qpd390_invoice_attachments_and_rpcs)
-- QPD-390: Support multi-file uploads and Add/Replace behavior
SET search_path TO qvm_new_apps, public;

-- 1) Table for Purchase Invoice attachments (multiple files per order)
CREATE TABLE IF NOT EXISTS qvm_new_apps.purchase_invoice_attachments (
  attachment_id bigserial PRIMARY KEY,
  confirmed_order_id int NOT NULL,
  purchase_order_id bigint NULL REFERENCES qvm_new_apps.purchase_orders(purchase_order_id) ON DELETE SET NULL,
  file_url text NOT NULL,
  file_path text,
  mime_type text,
  file_size int,
  invoice_number text,
  uploaded_by uuid,
  uploaded_at timestamptz DEFAULT now(),
  uploaded_source text CHECK (uploaded_source IN ('internal','vendor')) DEFAULT 'internal'
);

CREATE INDEX IF NOT EXISTS idx_pia_confirmed_order_id ON qvm_new_apps.purchase_invoice_attachments(confirmed_order_id);
CREATE INDEX IF NOT EXISTS idx_pia_purchase_order_id ON qvm_new_apps.purchase_invoice_attachments(purchase_order_id);

-- 2) RPC: Add Purchase Invoice Attachment (ADD mode)
CREATE OR REPLACE FUNCTION public.add_purchase_invoice_attachment(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_file_url text,
  p_invoice_number text DEFAULT NULL,
  p_file_path text DEFAULT NULL,
  p_mime_type text DEFAULT NULL,
  p_file_size int DEFAULT NULL,
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
  v_attachment_id bigint;
BEGIN
  SELECT user_type INTO v_user_type FROM user_data WHERE user_id = p_user_id;
  v_is_internal := (v_user_type = 185);
  IF NOT v_is_internal THEN
    RETURN jsonb_build_object('status','error','message','Access denied: Internal users only');
  END IF;

  -- Ensure a purchase_order exists (stub if needed)
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

  INSERT INTO purchase_invoice_attachments(
    confirmed_order_id, purchase_order_id, file_url, invoice_number, file_path, mime_type, file_size, uploaded_by, uploaded_at, uploaded_source
  ) VALUES (
    p_confirmed_order_id, v_purchase_order_id, p_file_url, NULLIF(p_invoice_number,''), p_file_path, p_mime_type, p_file_size, p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal')
  ) RETURNING attachment_id INTO v_attachment_id;

  RETURN jsonb_build_object('status','success','message','Attachment added','attachment_id', v_attachment_id, 'purchase_order_id', v_purchase_order_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.add_purchase_invoice_attachment(uuid, int, text, text, text, text, int, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_purchase_invoice_attachment(uuid, int, text, text, text, text, int, text) TO authenticated;

-- 3) RPC: Add Vendor Credit Note (ADD mode -> always insert new row)
CREATE OR REPLACE FUNCTION public.add_vendor_creditnote(
  p_user_id uuid,
  p_confirmed_order_id int,
  p_vendor_creditnote_url text,
  p_vendor_creditnote_number text DEFAULT NULL,
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

  INSERT INTO vendor_creditnotes(purchase_order_id, vendor_creditnote_url, vendor_creditnote_number, uploaded_by, uploaded_at, uploaded_source)
  VALUES (v_purchase_order_id, p_vendor_creditnote_url, NULLIF(p_vendor_creditnote_number,''), p_user_id, now(), COALESCE(NULLIF(p_uploaded_source,''),'internal'))
  RETURNING vendor_creditnote_id INTO v_vendor_creditnote_id;

  RETURN jsonb_build_object('status','success','message','Vendor credit note added','vendor_creditnote_id', v_vendor_creditnote_id, 'purchase_order_id', v_purchase_order_id);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.add_vendor_creditnote(uuid, int, text, text, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.add_vendor_creditnote(uuid, int, text, text, text) TO authenticated;;
