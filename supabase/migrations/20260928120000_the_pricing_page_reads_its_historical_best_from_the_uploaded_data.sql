-- The pricing page reads its Historical Best from the uploaded data.
--
-- The three tiles beside a line — best purchase price, best price before discount, best agency
-- price — and the history behind each were fed from a seed file in the frontend and from the
-- line's own fields. The catalogue on the Uploaded Data page already holds the real figures, per
-- cleaned part number: what vendors hold it for in stock (wholesale, and before discount) and
-- what the agency lists ask. One call returns, for a list of part numbers, the best of each and
-- every row behind it, so a tile shows the best and its history opens to the rows it came from.

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
