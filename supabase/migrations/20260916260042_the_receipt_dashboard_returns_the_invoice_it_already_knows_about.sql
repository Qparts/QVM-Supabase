-- The purchase-orders list knows which orders carry an invoice, and never said so.
--
-- get_purchase_orders_receipt_dashboard already selects vendor_invoice_url, its number, the Zoho
-- bill and the credit-note count into its `base` CTE — the «missing purchase invoice» filter is
-- built on exactly those four. They were simply never carried into the rows it returns, so a
-- screen could filter the list by «has no invoice» and could not show, per row, whether it had
-- one.
--
-- The alternative was for the page to open every order and read its items, which is forty round
-- trips to answer a question the first response already contained.
--
-- Four columns added to one select list. No new joins, no new work per row: the values are
-- already computed for the filter that sits above the same list.
do $do$
declare
  v_def text := pg_get_functiondef(
    'qvm_new_apps.get_purchase_orders_receipt_dashboard(uuid,boolean,text,integer[],integer[],integer,integer,boolean,boolean)'::regprocedure);
  v_old text := '               item_count, received_count, lower_qty_count, wrong_part_count, not_received_count,
               returned_count, total_approved_qty, total_returned_qty, total_value';
  v_new text := '               item_count, received_count, lower_qty_count, wrong_part_count, not_received_count,
               returned_count, total_approved_qty, total_returned_qty, total_value,
               -- The invoice this order already carries. Computed for the filter since the day
               -- that filter existed; now also answered for the row.
               vendor_invoice_url, vendor_invoice_number, zoho_bill_url, vcn_count';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'the receipt dashboard select list is not where this expects it (% hits)', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;
