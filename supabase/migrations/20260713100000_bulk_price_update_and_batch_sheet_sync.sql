-- Setting many item prices in quick succession (each save = its own UPDATE statement) fires the
-- write_price_to_sheet trigger once per row, so N concurrent net.http_post calls race each other
-- against the AppSheet API and some updates get dropped. Fix:
--   1) A new bulk price-update RPC that updates every item in one set-based UPDATE statement.
--   2) Convert the price-sync trigger from FOR EACH ROW to FOR EACH STATEMENT (using transition
--      tables), so a single multi-row UPDATE — from the new bulk RPC or anywhere else — batches
--      every changed item into ONE call to write_price_to_sheet. Existing single-row saves are
--      unaffected: one row updated per statement still means one id per sheet-sync call, exactly
--      as before.

-- 1) Bulk price update: one UPDATE for the whole batch.
CREATE OR REPLACE FUNCTION qvm_new_apps.update_quotation_item_prices_bulk(p_updates jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  updated jsonb;
BEGIN
  WITH changes AS (
    SELECT
      (x->>'quotation_item_id')::int          AS quotation_item_id,
      (x->>'price_before_vat')::numeric        AS price_before_vat,
      NULLIF(x->>'agency_price','')::numeric    AS agency_price,
      NULLIF(x->>'discount_percent','')::numeric AS discount_percent
    FROM jsonb_array_elements(p_updates) AS x
  ),
  upd AS (
    UPDATE qvm_new_apps.quotation_items qi
    SET
      price_before_vat       = c.price_before_vat,
      agency_price           = COALESCE(c.agency_price, qi.agency_price),
      discount_percent       = COALESCE(c.discount_percent, qi.discount_percent),
      total_price_before_vat = c.price_before_vat * qi.quantity,
      item_status            = CASE WHEN qi.item_status IS NULL OR qi.item_status IN (236, 235, 237) THEN 17 ELSE qi.item_status END,
      updated_at              = NOW()
    FROM changes c
    WHERE qi.quotation_item_id = c.quotation_item_id
    RETURNING qi.quotation_item_id, qi.price_before_vat, qi.agency_price, qi.discount_percent,
              qi.total_price_before_vat, qi.item_status
  )
  SELECT COALESCE(jsonb_agg(to_jsonb(upd.*)), '[]'::jsonb)
  INTO updated
  FROM upd;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'Bulk price update completed',
    'updated_count', COALESCE(jsonb_array_length(updated), 0),
    'updated', updated
  );
END;
$function$;

-- 2) Convert the price-sync trigger to statement-level so any single UPDATE statement affecting
--    multiple rows (like the bulk RPC above) syncs to the sheet exactly once.
DROP TRIGGER IF EXISTS trg_write_price_to_sheet_on_priced ON qvm_new_apps.quotation_items;
DROP FUNCTION IF EXISTS qvm_new_apps.trg_write_price_to_sheet_on_priced();

CREATE OR REPLACE FUNCTION qvm_new_apps.trg_write_price_to_sheet_on_priced_stmt()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO qvm_new_apps, extensions, public
AS $$
DECLARE
  v_url text := 'https://vvkulhfjtznozgxiqluj.supabase.co/functions/v1/write_price_to_sheet';
  v_headers jsonb := jsonb_build_object('Content-Type', 'application/json');
  v_ids jsonb;
BEGIN
  SELECT COALESCE(jsonb_agg(n.quotation_item_id), '[]'::jsonb)
  INTO v_ids
  FROM new_rows n
  JOIN old_rows o ON o.quotation_item_id = n.quotation_item_id
  WHERE n.item_status = 17 OR n.price_before_vat IS DISTINCT FROM o.price_before_vat;

  IF jsonb_array_length(v_ids) > 0 THEN
    PERFORM net.http_post(v_url, jsonb_build_object('quotation_item_ids', v_ids), '{}'::jsonb, v_headers, 10000);
  END IF;

  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_write_price_to_sheet_on_priced_stmt
AFTER UPDATE ON qvm_new_apps.quotation_items
REFERENCING NEW TABLE AS new_rows OLD TABLE AS old_rows
FOR EACH STATEMENT
EXECUTE FUNCTION qvm_new_apps.trg_write_price_to_sheet_on_priced_stmt();
