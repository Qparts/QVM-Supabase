-- A receipt can be submitted unsigned.
--
-- The signature was mandatory, which left the PO number the receiver had typed with nowhere to go
-- whenever the pad was left blank. Both are now recorded, and signed_note_at stamps only when there
-- really is a signature — so "signed" still means signed, and an unsigned receipt is simply a
-- receipt nobody has put their name to yet.

CREATE OR REPLACE FUNCTION qvm_new_apps.sign_purchase_receipt_round(
  p_receipt_round_id bigint,
  p_signature text,
  p_po_number text DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_po_id bigint;
  v_signature text := NULLIF(trim(COALESCE(p_signature, '')), '');
BEGIN
  SELECT purchase_order_id INTO v_po_id
  FROM qvm_new_apps.purchase_receipt_rounds WHERE receipt_round_id = p_receipt_round_id;

  IF v_po_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Receipt round not found');
  END IF;
  IF NOT qvm_new_apps.can_access_purchase_order(v_po_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied');
  END IF;

  UPDATE qvm_new_apps.purchase_receipt_rounds
  SET signature      = COALESCE(v_signature, signature),
      po_number      = NULLIF(trim(COALESCE(p_po_number, '')), ''),
      -- Never un-stamp a receipt that was already signed.
      signed_note_at = CASE WHEN v_signature IS NOT NULL THEN now() ELSE signed_note_at END
  WHERE receipt_round_id = p_receipt_round_id;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object(
    'receipt_round_id', p_receipt_round_id,
    'signed', v_signature IS NOT NULL));
END;
$function$;
