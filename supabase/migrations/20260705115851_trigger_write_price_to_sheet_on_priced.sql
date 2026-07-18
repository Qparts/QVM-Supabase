-- Synced from QVM/test branch applied migration history (version 20260705115851, name: trigger_write_price_to_sheet_on_priced)
-- Trigger write_price_to_sheet edge function when quotation_items.item_status is Priced (17)
BEGIN;
SET search_path TO qvm_new_apps, extensions, public;

CREATE OR REPLACE FUNCTION qvm_new_apps.trg_write_price_to_sheet_on_priced()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_url text;
  v_body jsonb;
  v_headers jsonb;
BEGIN
  IF NEW.item_status = 17 THEN
    v_url := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_price_to_sheet';
    v_body := jsonb_build_object('quotation_item_ids', jsonb_build_array(NEW.quotation_item_id));
    v_headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZ2a3VsaGZqdHpub3pneGlxbHVqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzA1MDA4MjMsImV4cCI6MjA2NjA3NjgyM30.r4J7mip2_OEcI3nf18jHDqvg-MdUXRdrGNZ6Gcz2_aE'
    );
    PERFORM net.http_post(v_url, v_body, '{}'::jsonb, v_headers, 10000);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_write_price_to_sheet_on_priced ON qvm_new_apps.quotation_items;
CREATE TRIGGER trg_write_price_to_sheet_on_priced
AFTER UPDATE ON qvm_new_apps.quotation_items
FOR EACH ROW
EXECUTE FUNCTION qvm_new_apps.trg_write_price_to_sheet_on_priced();

COMMIT;
;
