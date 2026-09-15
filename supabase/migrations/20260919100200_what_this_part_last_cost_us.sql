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

-- Clear the way first.
--
-- CREATE OR REPLACE cannot change a function's return type or its argument names, and this project
-- is full of functions that exist only in the live database and in no migration — get_brand_classes
-- and get_parts_pricing_history are both like that. If one of the names below is already taken by
-- such a function with a different shape, the CREATE fails and takes the whole deploy with it,
-- which is what happened the first time this file went out.
--
-- Dropping every overload by name rather than by signature, because a signature-specific DROP
-- misses exactly the case that causes the failure. None of these names is referenced anywhere in
-- this repository, so nothing here can be pulling the rug from under a caller.
DO $drop$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS sig
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname IN ('public', 'qvm_new_apps')
              AND p.proname IN ('last_purchase_prices')
  LOOP
    EXECUTE 'DROP FUNCTION IF EXISTS ' || r.sig || ' CASCADE';
  END LOOP;
END
$drop$;

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
           -- The order number is the QUOTATION's. purchase_orders does not carry one: it hangs off
           -- confirmed_order_id, and the human-readable number lives on the order the parts came
           -- from. Reading po.order_number is what broke this file's first two deploys.
           q.order_number                                      AS order_number,
           v.vendor_name                                       AS vendor_name
      FROM qvm_new_apps.purchase_items pi
      JOIN qvm_new_apps.purchase_orders po      ON po.purchase_order_id = pi.purchase_order_id
      JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = pi.cost_id
      JOIN qvm_new_apps.quotation_items qi      ON qi.quotation_item_id = qvi.quotation_item_id
      JOIN qvm_new_apps.quotations q            ON q.quotation_id = qi.quotation_id
      -- The PO's own vendor when it has one; the quoted line's vendor otherwise. They are the same
      -- vendor in every ordinary case, but the PO is the document that actually bought the part.
      LEFT JOIN qvm_new_apps.vendors v          ON v.vendor_id = COALESCE(po.vendor_id, qvi.vendor_id)
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
