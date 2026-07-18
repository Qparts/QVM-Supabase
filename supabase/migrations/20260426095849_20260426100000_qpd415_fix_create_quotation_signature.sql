-- Synced from QVM/test branch applied migration history (version 20260426095849, name: 20260426100000_qpd415_fix_create_quotation_signature)
BEGIN;

-- QPD-415: Ensure public.create_quotation accepts text order_number and does not cast it to integer
CREATE OR REPLACE FUNCTION public.create_quotation(
  p_order_number text,
  p_plate_number text,
  p_order_type integer,
  p_delivery_type integer,
  p_service_advisor uuid,
  p_account_manager uuid
)
RETURNS qvm_new_apps.quotations
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_quotation qvm_new_apps.quotations;
BEGIN
  INSERT INTO qvm_new_apps.quotations (
    order_number,
    plate_number,
    order_type,
    delivery_type,
    service_advisor,
    account_manager,
    shipping_type
  ) VALUES (
    p_order_number::text,
    p_plate_number::text,
    p_order_type,
    p_delivery_type,
    p_service_advisor,
    p_account_manager,
    'item'
  )
  RETURNING * INTO v_quotation;

  RETURN v_quotation;
END;
$$;

-- Grants
GRANT EXECUTE ON FUNCTION public.create_quotation(text, text, integer, integer, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_quotation(text, text, integer, integer, uuid, uuid) TO service_role;

COMMIT;
;
