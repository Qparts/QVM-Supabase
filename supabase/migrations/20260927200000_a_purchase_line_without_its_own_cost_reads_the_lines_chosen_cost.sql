-- A purchase line without its own cost reads the line's chosen cost.
--
-- 42 of the 104 purchase lines on dev showed no price: their purchase_items row names no vendor
-- line (cost_id is null) and carries no final price, so the two places the view looked were both
-- empty. Every one of them, though, sits on a quotation line whose chosen cost is set — cost_id
-- on quotation_items, the vendor price the buyer picked when the line was confirmed. That is the
-- price the purchase was made at, so the view now falls back to it (and to selected_cost_id after
-- it), and takes the vendor from the same place when the purchase order names none. A zero is
-- treated as no price rather than a price of nothing.

DROP VIEW IF EXISTS qvm_new_apps.part_purchases_v;
CREATE VIEW qvm_new_apps.part_purchases_v AS
  SELECT pi.purchase_item_id, pi.purchase_order_id, po.confirmed_order_id,
         qvm_new_apps.normalize_part_number(qi.part_number) AS clean_part_number,
         qi.part_number AS raw_part_number, qi.part_description,
         mb.list_data AS make, bc.list_data AS part_class,
         q.order_number,
         COALESCE(po.vendor_id, qvi.vendor_id, lc.vendor_id, sc.vendor_id) AS vendor_id, v.vendor_name, vb.branch_name AS vendor_branch,
         pi.approved_qty, pi.received_qty, pi.returned_qty,
         -- The buyer's final price; else the vendor line the purchase item names; else the cost
         -- chosen on the quotation line itself (cost_id, then selected_cost_id). A zero is not a
         -- price.
         COALESCE(NULLIF(pi.final_purchase_price, 0), NULLIF(qvi.cost, 0), NULLIF(lc.cost, 0), NULLIF(sc.cost, 0))::numeric AS unit_price,
         (COALESCE(NULLIF(pi.final_purchase_price, 0), NULLIF(qvi.cost, 0), NULLIF(lc.cost, 0), NULLIF(sc.cost, 0)) * COALESCE(pi.approved_qty, 0))::numeric AS line_total,
         pi.vendor_shipping_cost::numeric AS vendor_shipping_cost,
         st.list_data AS status, pi.receipt_status,
         po.created_at AS bought_at
    FROM qvm_new_apps.purchase_items pi
    JOIN qvm_new_apps.purchase_orders po ON po.purchase_order_id = pi.purchase_order_id
    JOIN qvm_new_apps.confirmed_items ci ON ci.confirmed_item_id = pi.confirmed_item_id
    JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = ci.quotation_item_id
    JOIN qvm_new_apps.quotations q ON q.quotation_id = qi.quotation_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = pi.cost_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items lc ON lc.cost_id = qi.cost_id
    LEFT JOIN qvm_new_apps.quotation_vendor_items sc ON sc.cost_id = qi.selected_cost_id
    LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = COALESCE(po.vendor_id, qvi.vendor_id, lc.vendor_id, sc.vendor_id)
    LEFT JOIN qvm_new_apps.vendor_branches vb ON vb.vendor_branch_id = po.vendor_branch_id
    LEFT JOIN qvm_new_apps.list_data mb ON mb.list_data_id = qi.main_brand
    LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = qi.brand_class
    LEFT JOIN qvm_new_apps.list_data st ON st.list_data_id = pi.vendor_item_status
   WHERE COALESCE(qvm_new_apps.normalize_part_number(qi.part_number), '') <> '';
GRANT SELECT ON qvm_new_apps.part_purchases_v TO service_role;
