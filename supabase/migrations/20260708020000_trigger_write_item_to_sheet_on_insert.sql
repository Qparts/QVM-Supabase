-- Trigger: call write_item_to_sheet edge function when a new quotation item is inserted
CREATE OR REPLACE FUNCTION qvm_new_apps.trg_write_item_to_sheet_on_insert()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = net, public
AS $$
DECLARE
  v_url      text := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_item_to_sheet';
  v_headers  jsonb;
  v_body     jsonb;
BEGIN
  v_headers := jsonb_build_object(
    'Content-Type', 'application/json'
  );

  v_body := jsonb_build_object(
    'quotation_item_id', NEW.quotation_item_id,
    'quotation_id', NEW.quotation_id
  );

  PERFORM net.http_post(
    url     := v_url,
    headers := v_headers,
    body    := v_body
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_write_item_to_sheet_on_insert ON qvm_new_apps.quotation_items;

CREATE TRIGGER trg_write_item_to_sheet_on_insert
  AFTER INSERT ON qvm_new_apps.quotation_items
  FOR EACH ROW
  EXECUTE FUNCTION qvm_new_apps.trg_write_item_to_sheet_on_insert();
