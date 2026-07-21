-- write_price_to_sheet now owns the "Delivery Status" = "Priced" write for the item_status = 17
-- transition (see supabase/functions/write_price_to_sheet/index.ts header). Excluding that one
-- status value from this trigger's WHEN clause means it never fires for the same UPDATE that
-- fires trg_write_price_to_sheet_on_priced, so the two edge functions can no longer race each
-- other writing "Delivery Status" on the same AppSheet row. Every other item_status transition
-- is untouched - this trigger still owns "Delivery Status" for all of them.
DROP TRIGGER IF EXISTS trg_update_item_status_in_sheet ON qvm_new_apps.quotation_items;

CREATE TRIGGER trg_update_item_status_in_sheet
  AFTER UPDATE ON qvm_new_apps.quotation_items
  FOR EACH ROW
  WHEN (NEW.item_status IS DISTINCT FROM OLD.item_status AND NEW.item_status IS DISTINCT FROM 17)
  EXECUTE FUNCTION qvm_new_apps.trg_update_item_status_in_sheet();
