-- What this part last cost us.
--
-- The pricing page is about to stop letting a buyer quietly pay more than the company paid last
-- time. To do that it needs one number per part: the price on the most recent purchase order that
-- actually bought it, and how long ago that was.
--
-- Read from purchase_items rather than from quotation_vendor_items. A vendor's quoted cost is a
-- price someone offered; purchase_items.final_purchase_price is a price the company paid. Only the
-- second is a fact worth measuring a new quote against.
--
-- final_purchase_price is COALESCEd to the vendor's cost because the field is filled in when the
-- invoice lands: a purchase order raised last week has been bought at a price even though nobody
-- has typed the final figure yet, and ignoring it would make the most recent purchase invisible.

CREATE OR REPLACE FUNCTION qvm_new_apps.last_purchase_prices(p_part_numbers text[])
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  WITH wanted AS (
    SELECT DISTINCT upper(btrim(pn)) AS key
      FROM unnest(COALESCE(p_part_numbers, ARRAY[]::text[])) AS pn
     WHERE COALESCE(btrim(pn), '') <> ''
  ),
  bought AS (
    SELECT upper(btrim(qi.part_number))                        AS key,
           COALESCE(pi.final_purchase_price, qvi.cost)         AS price,
           po.created_at                                       AS bought_at,
           po.order_number                                     AS order_number,
           v.vendor_name                                       AS vendor_name
      FROM qvm_new_apps.purchase_items pi
      JOIN qvm_new_apps.purchase_orders po      ON po.purchase_order_id = pi.purchase_order_id
      JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = pi.cost_id
      JOIN qvm_new_apps.quotation_items qi      ON qi.quotation_item_id = qvi.quotation_item_id
      LEFT JOIN qvm_new_apps.vendors v          ON v.vendor_id = qvi.vendor_id
      JOIN wanted w ON w.key = upper(btrim(qi.part_number))
     WHERE COALESCE(pi.final_purchase_price, qvi.cost) IS NOT NULL
       AND COALESCE(pi.final_purchase_price, qvi.cost) > 0
  ),
  latest AS (
    SELECT DISTINCT ON (key) key, price, bought_at, order_number, vendor_name
      FROM bought
     ORDER BY key, bought_at DESC
  )
  SELECT COALESCE(jsonb_object_agg(l.key, jsonb_build_object(
           'price',        l.price,
           'bought_at',    l.bought_at,
           'order_number', l.order_number,
           'vendor_name',  l.vendor_name)), '{}'::jsonb)
    FROM latest l;
$function$;

CREATE OR REPLACE FUNCTION public.last_purchase_prices(p_part_numbers text[])
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.last_purchase_prices(p_part_numbers); $$;

REVOKE ALL ON FUNCTION public.last_purchase_prices(text[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.last_purchase_prices(text[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.last_purchase_prices(text[]) TO authenticated, service_role;
