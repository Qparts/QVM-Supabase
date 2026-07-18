-- Synced from QVM/test branch applied migration history (version 20260621012506, name: add_get_price_history_public_wrapper)
CREATE OR REPLACE FUNCTION public.get_price_history(p_quotation_item_id integer)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT qvm_new_apps.get_price_history(p_quotation_item_id);
$$;;
