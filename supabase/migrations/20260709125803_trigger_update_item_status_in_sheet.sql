-- Synced from QVM/test branch applied migration history (version 20260709125803, name: trigger_update_item_status_in_sheet)
CREATE OR REPLACE FUNCTION qvm_new_apps.trg_update_item_status_in_sheet()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = net, public
AS $$
BEGIN
  PERFORM net.http_post(
    url     := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/update_item_status_in_sheet',
    headers := jsonb_build_object('Content-Type', 'application/json'),
    body    := jsonb_build_object('quotation_item_id', NEW.quotation_item_id)
  );
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_update_item_status_in_sheet ON qvm_new_apps.quotation_items;

CREATE TRIGGER trg_update_item_status_in_sheet
  AFTER UPDATE ON qvm_new_apps.quotation_items
  FOR EACH ROW
  WHEN (NEW.item_status IS DISTINCT FROM OLD.item_status)
  EXECUTE FUNCTION qvm_new_apps.trg_update_item_status_in_sheet();
;
