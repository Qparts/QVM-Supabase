-- The best purchase price is what was actually bought.
--
-- The purchase tile read the uploaded stock's wholesale price. A purchase price is what the
-- company paid: the purchase-order lines the Purchased items tab lists. The reference call now
-- returns those too — the lowest unit price ever paid, the latest one, and every purchase line
-- behind them — and the tile and its history read from there. Stock keeps feeding the
-- before-discount tile; the agency lists keep feeding the agency tile.

CREATE OR REPLACE FUNCTION qvm_new_apps.part_reference_prices(p_part_numbers text[])
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_out jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'Not signed in'); END IF;
  IF NOT qvm_new_apps.is_qparts_team() THEN RETURN jsonb_build_object('success', false, 'error', 'Access denied'); END IF;
  WITH wanted AS (
    SELECT DISTINCT qvm_new_apps.normalize_part_number(pn) AS key, pn AS raw
      FROM unnest(COALESCE(p_part_numbers, ARRAY[]::text[])) AS pn
     WHERE COALESCE(qvm_new_apps.normalize_part_number(pn), '') <> ''
  ),
  stock AS (
    SELECT w.key,
           jsonb_build_object(
             'id', i.id, 'vendor', v.vendor_name, 'branch', vb.branch_name, 'city', vb.city,
             'wholesale_price', i.wholesale_price, 'before_discount_price', i.before_discount_price,
             'retail_price', i.retail_price, 'quantity', i.quantity, 'is_available', i.is_available,
             'as_of', i.updated_at,
             'source_file', (SELECT b.file_name FROM qvm_new_apps.upload_batches b WHERE b.batch_id = i.batch_id)) AS row,
           i.wholesale_price, i.before_discount_price, i.updated_at
      FROM wanted w
      JOIN qvm_new_apps.inventory_stock i ON i.clean_part_number = w.key
      LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = i.vendor_id
      LEFT JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = i.vendor_branch_id
  ),
  bought AS (
    SELECT w.key,
           jsonb_build_object(
             'id', b.purchase_item_id, 'vendor', b.vendor_name, 'branch', b.vendor_branch,
             'order_number', b.order_number, 'purchase_order_id', b.purchase_order_id,
             'quantity', b.approved_qty, 'received_qty', b.received_qty,
             'unit_price', b.unit_price, 'line_total', b.line_total,
             'status', b.status, 'receipt_status', b.receipt_status,
             'as_of', b.bought_at) AS row,
           b.unit_price, b.bought_at
      FROM wanted w
      JOIN qvm_new_apps.part_purchases_v b ON b.clean_part_number = w.key
  ),
  agency AS (
    SELECT w.key,
           jsonb_build_object(
             'id', a.id, 'vendor', COALESCE(v.vendor_name, a.source_label), 'branch', COALESCE(cbr.branch_name, vb.branch_name),
             'agency_price', a.agency_price, 'after_discount', a.agency_price_after_discount,
             'discount_pct', a.dealer_agency_discount_pct,
             'effective_from', a.effective_from, 'expires_on', a.expires_on, 'as_of', a.updated_at,
             'source_file', (SELECT b.file_name FROM qvm_new_apps.upload_batches b WHERE b.batch_id = a.batch_id)) AS row,
           a.agency_price, a.updated_at
      FROM wanted w
      JOIN qvm_new_apps.agency_price_reference a ON a.clean_part_number = w.key
      LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = a.vendor_id
      LEFT JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = a.vendor_branch_id
      LEFT JOIN qvm_new_apps.client_branches cbr ON cbr.customer_id = a.client_branch_id
  )
  SELECT COALESCE(jsonb_object_agg(w.key, jsonb_build_object(
           -- what was actually bought on purchase orders, lowest unit price first
           'purchases', jsonb_build_object(
             'best', (SELECT min(b.unit_price) FROM bought b WHERE b.key = w.key AND b.unit_price > 0),
             'last', (SELECT b.unit_price FROM bought b WHERE b.key = w.key AND b.unit_price > 0 ORDER BY b.bought_at DESC NULLS LAST LIMIT 1),
             'rows', COALESCE((SELECT jsonb_agg(b.row ORDER BY b.unit_price NULLS LAST, b.bought_at DESC) FROM bought b WHERE b.key = w.key), '[]'::jsonb)),
           'stock', jsonb_build_object(
             'best_wholesale', (SELECT min(s.wholesale_price) FROM stock s WHERE s.key = w.key AND s.wholesale_price > 0),
             'best_before_discount', (SELECT min(s.before_discount_price) FROM stock s WHERE s.key = w.key AND s.before_discount_price > 0),
             'rows', COALESCE((SELECT jsonb_agg(s.row ORDER BY s.wholesale_price NULLS LAST, s.updated_at DESC) FROM stock s WHERE s.key = w.key), '[]'::jsonb)),
           'agency', jsonb_build_object(
             'best', (SELECT min(a.agency_price) FROM agency a WHERE a.key = w.key AND a.agency_price > 0),
             'rows', COALESCE((SELECT jsonb_agg(a.row ORDER BY a.agency_price NULLS LAST, a.updated_at DESC) FROM agency a WHERE a.key = w.key), '[]'::jsonb))
         )), '{}'::jsonb)
    INTO v_out
    FROM (SELECT DISTINCT key FROM wanted) w;
  RETURN jsonb_build_object('success', true, 'data', v_out);
END $$;

CREATE OR REPLACE FUNCTION public.part_reference_prices(p_part_numbers text[]) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.part_reference_prices(p_part_numbers) $$;
