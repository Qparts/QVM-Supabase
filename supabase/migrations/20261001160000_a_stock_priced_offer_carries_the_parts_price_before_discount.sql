-- A stock-priced offer carries the part's price before discount as its customer price.
--
-- A vendor branch that receives automatic RFQs is priced from its stock file the moment it is
-- asked: the offer's cost is the file's wholesale price. The pricing page fills the customer price
-- (سعر العميل) from an offer's agency_price — the vendor's price before discount — and a stock-priced
-- offer had none, so the desk saw no customer price for it. Now the file's price before discount
-- travels with the automatic send and lands on the offer as its agency_price, and the offers
-- already priced from stock get theirs from the stock rows they were priced from.

ALTER TABLE qvm_new_apps.auto_rfq_sends ADD COLUMN IF NOT EXISTS stock_before_discount numeric;
COMMENT ON COLUMN qvm_new_apps.auto_rfq_sends.stock_before_discount IS
  'The stock row''s price before discount at send time; becomes the offer''s agency_price (the customer price) when the stock price is applied.';

CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_on_part_number()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_pn text := qvm_new_apps.normalize_part_number(new.part_number);
  v_n  integer := 0;
begin
  if v_pn is null then return new; end if;
  if tg_op = 'UPDATE'
     and qvm_new_apps.normalize_part_number(old.part_number) is not distinct from v_pn then
    return new;
  end if;
  -- A line already priced, delivered or cancelled is not tendered again.
  if new.item_status in (17, 19, 21, 22, 23, 31) or new.cancellation_reason is not null then
    return new;
  end if;

  with hits as (
    -- One row per branch: the freshest stock line for the part decides the price.
    select distinct on (s.vendor_branch_id)
           s.id, s.vendor_id, s.vendor_branch_id, s.wholesale_price, s.quantity,
           -- The part's price before discount on the file: the customer price the offer will carry.
           s.before_discount_price
      from qvm_new_apps.inventory_stock s
      join qvm_new_apps.vendor_branches vb on vb.vendor_branch_id = s.vendor_branch_id
     where s.clean_part_number = v_pn
       and s.is_available
       and s.wholesale_price > 0
       and vb.auto_receive_rfqs
       and coalesce(vb.is_active, true)
     order by s.vendor_branch_id, s.updated_at desc, s.id desc
  ), ins as (
    insert into qvm_new_apps.auto_rfq_sends
      (rule_id, source, quotation_id, quotation_item_id, vendor_id, vendor_branch_id, trigger_status,
       stock_id, stock_cost, stock_qty, stock_before_discount)
    select null, 'stock', new.quotation_id, new.quotation_item_id, h.vendor_id, h.vendor_branch_id,
           coalesce(new.item_status, 0), h.id, h.wholesale_price, h.quantity, nullif(h.before_discount_price, 0)
      from hits h
     -- A branch that already has this line — by hand or by rule — is not asked again.
     where not exists (select 1 from qvm_new_apps.quotation_vendor_items qvi
                         join qvm_new_apps.quotation_vendors qv on qv.quotation_vendor_id = qvi.quotation_vendor_id
                        where qvi.quotation_item_id = new.quotation_item_id
                          and qv.vendor_id = h.vendor_id
                          and qv.vendor_branch_id is not distinct from h.vendor_branch_id)
    on conflict do nothing
    returning 1)
  select count(*) into v_n from ins;

  if v_n > 0 then
    perform qvm_new_apps.auto_rfq_wake(new.quotation_id);
  end if;
  return new;
exception when others then
  -- Automation never blocks the order it is trying to help.
  return new;
end $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_apply_stock_prices(p_send_ids bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare v_n integer := 0; v_qv bigint;
begin
  with hit as (
    update qvm_new_apps.quotation_vendor_items qvi
       set cost = s.stock_cost,
           -- The customer price the pricing page fills from this offer: the part's price before
           -- discount on the vendor's stock file, as captured at send time (or read from the stock
           -- row if the send predates the column). Left as it was when the file named none.
           agency_price = coalesce(nullif(s.stock_before_discount, 0),
                                   (select nullif(st.before_discount_price, 0) from qvm_new_apps.inventory_stock st where st.id = s.stock_id),
                                   qvi.agency_price),
           available_quantity = coalesce(s.stock_qty, qvi.available_quantity),
           vendor_item_status = 158,
           price_source = 'stock_file',
           from_database = true,
           updated_at = now()
      from qvm_new_apps.auto_rfq_sends s
      join qvm_new_apps.quotation_vendors qv
        on qv.quotation_id = s.quotation_id and qv.vendor_id = s.vendor_id
       and qv.vendor_branch_id is not distinct from s.vendor_branch_id
     where s.send_id = any(p_send_ids)
       and s.source = 'stock' and s.status = 'sent' and s.stock_cost > 0
       and qvi.quotation_vendor_id = qv.quotation_vendor_id
       and qvi.quotation_item_id = s.quotation_item_id
       and coalesce(qvi.cost, 0) = 0
       and coalesce(qvi.vendor_item_status, 157) = 157
    returning qvi.quotation_vendor_id)
  select count(*) into v_n from hit;

  for v_qv in
    select distinct qv.quotation_vendor_id
      from qvm_new_apps.auto_rfq_sends s
      join qvm_new_apps.quotation_vendors qv
        on qv.quotation_id = s.quotation_id and qv.vendor_id = s.vendor_id
       and qv.vendor_branch_id is not distinct from s.vendor_branch_id
     where s.send_id = any(p_send_ids) and s.source = 'stock'
  loop
    perform qvm_new_apps.update_vendor_status(v_qv);
  end loop;

  return jsonb_build_object('status', true, 'priced', v_n);
end $function$;

-- Offers already priced from stock: the customer price from the stock row each was priced from.
UPDATE qvm_new_apps.quotation_vendor_items qvi
   SET agency_price = st.before_discount_price, updated_at = now()
  FROM qvm_new_apps.auto_rfq_sends s
  JOIN qvm_new_apps.quotation_vendors qv
    ON qv.quotation_id = s.quotation_id AND qv.vendor_id = s.vendor_id
   AND qv.vendor_branch_id IS NOT DISTINCT FROM s.vendor_branch_id
  JOIN qvm_new_apps.inventory_stock st ON st.id = s.stock_id
 WHERE s.source = 'stock' AND s.status = 'sent'
   AND qvi.quotation_vendor_id = qv.quotation_vendor_id
   AND qvi.quotation_item_id = s.quotation_item_id
   AND qvi.price_source = 'stock_file'
   AND COALESCE(qvi.agency_price, 0) = 0
   AND st.before_discount_price > 0;
