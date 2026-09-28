-- A branch that takes automatic RFQs is asked the moment an order line names a part its stock file holds.
--
-- The vendor uploads a stock file for a branch and turns on «Receives automatic RFQs» on that
-- branch. From then on, whenever the system sets a line's part number — on the order's creation or
-- on a later correction — every such branch whose live stock (inventory_stock) holds that part is
-- sent the line, through the same queue, dispatcher and send path as the rule-based automatic
-- RFQs. Once the RFQ is delivered, the branch's line is priced from the file (wholesale_price,
-- quantity), marked as priced and stamped price_source = 'stock_file'. The vendor's own screens
-- keep such a line open, so the vendor can change the price; once they save one, it is theirs.
--
-- Sends carry their origin: 'rule' (a branch/brand rule matched) or 'stock' (the part was in the
-- branch's stock file). The unique key on (line, vendor, branch) still guarantees one RFQ per
-- branch per line whichever path queued it first.

set search_path to qvm_new_apps, public;

alter table qvm_new_apps.auto_rfq_sends
  add column if not exists source     text    not null default 'rule',
  add column if not exists stock_id   bigint,
  add column if not exists stock_cost numeric,
  add column if not exists stock_qty  integer;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'auto_rfq_sends_source_check') then
    alter table qvm_new_apps.auto_rfq_sends
      add constraint auto_rfq_sends_source_check check (source in ('rule', 'stock'));
  end if;
end $$;

-- The price history only admitted five legacy source names, so every price the app stamped as
-- «manual» or «ai_extracted» — and now «stock_file» — was refused by the check and, because the
-- logging trigger swallows errors, silently never recorded. The names the app writes are admitted.
alter table qvm_new_apps.cost_logs drop constraint if exists cost_logs_pricing_source_chk;
alter table qvm_new_apps.cost_logs add constraint cost_logs_pricing_source_chk
  check (pricing_source is null or pricing_source in
         ('Powerbi', 'SOP', 'Inventory File', 'Contact Supplier', 'On-Site Pricing',
          'manual', 'ai_extracted', 'stock_file'));

-- Wakes the dispatcher for one order: the same pg_net call the rule trigger makes, shared.
create or replace function qvm_new_apps.auto_rfq_wake(p_quotation_id bigint)
 returns void
 language plpgsql
 security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_url text; v_secret text;
begin
  select s.value into v_url from qvm_new_apps.auto_rfq_settings s where s.key = 'dispatch_url';
  begin
    select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'auto_rfq_dispatch_secret';
  exception when others then v_secret := null; end;
  if nullif(btrim(coalesce(v_url, '')), '') is not null and v_secret is not null then
    begin
      perform net.http_post(
        url     := v_url,
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-auto-rfq-secret', v_secret),
        body    := jsonb_build_object('quotation_id', p_quotation_id));
    exception when others then null; end;
  end if;
end $function$;

-- The line's part number was set. Queue it for every branch that takes automatic RFQs and whose
-- stock file holds the part, with the file's price and quantity as they stand now.
create or replace function qvm_new_apps.auto_rfq_on_part_number()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
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
           s.id, s.vendor_id, s.vendor_branch_id, s.wholesale_price, s.quantity
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
       stock_id, stock_cost, stock_qty)
    select null, 'stock', new.quotation_id, new.quotation_item_id, h.vendor_id, h.vendor_branch_id,
           coalesce(new.item_status, 0), h.id, h.wholesale_price, h.quantity
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

drop trigger if exists trg_auto_rfq_on_part_number on qvm_new_apps.quotation_items;
create trigger trg_auto_rfq_on_part_number
  after insert or update of part_number on qvm_new_apps.quotation_items
  for each row execute function qvm_new_apps.auto_rfq_on_part_number();

-- After the RFQ went out: the branch's lines that came from its stock file are priced from it.
-- Only a line the vendor has not priced yet is touched; the vendor's own number always wins.
create or replace function qvm_new_apps.auto_rfq_apply_stock_prices(p_send_ids bigint[])
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'qvm_new_apps', 'public'
as $function$
declare v_n integer := 0; v_qv bigint;
begin
  with hit as (
    update qvm_new_apps.quotation_vendor_items qvi
       set cost = s.stock_cost,
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

CREATE OR REPLACE FUNCTION qvm_new_apps.auto_rfq_claim(p_quotation_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE v jsonb;
BEGIN
  -- A data-modifying CTE has to be the statement's top level, hence the INTO rather than a subselect.
  WITH c AS (
    UPDATE qvm_new_apps.auto_rfq_sends s SET status = 'sending'
     WHERE s.quotation_id = p_quotation_id AND s.status = 'queued'
    RETURNING s.send_id, s.rule_id, s.quotation_item_id, s.vendor_id, s.vendor_branch_id, s.trigger_status,
              s.source, s.stock_cost, s.stock_qty)
  SELECT jsonb_agg(to_jsonb(c)) INTO v FROM c;
  RETURN COALESCE(v, '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_auto_rfq_sends(p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  PERFORM qvm_new_apps.auto_rfq_assert_admin();
  RETURN COALESCE((
    SELECT jsonb_agg(x.payload ORDER BY x.created_at DESC) FROM (
      SELECT s.created_at, jsonb_build_object(
               'send_id', s.send_id, 'rule_id', s.rule_id, 'quotation_id', s.quotation_id,
               'order_number', q.order_number, 'quotation_item_id', s.quotation_item_id,
               'part_number', qi.part_number, 'part_description', qi.part_description,
               'vendor_id', s.vendor_id, 'vendor_name', v.vendor_name, 'vendor_branch_id', s.vendor_branch_id,
               'trigger_status', s.trigger_status,
               'trigger_status_name', CASE WHEN s.source = 'stock' THEN 'Stock file match'
                                           ELSE qvm_new_apps.auto_rfq_status_name(s.trigger_status) END,
               'source', s.source, 'stock_cost', s.stock_cost, 'stock_qty', s.stock_qty,
               'status', s.status, 'error', s.error, 'webhook_log_id', s.webhook_log_id,
               'created_at', s.created_at, 'sent_at', s.sent_at) AS payload
        FROM qvm_new_apps.auto_rfq_sends s
        LEFT JOIN qvm_new_apps.quotations q ON q.quotation_id = s.quotation_id
        LEFT JOIN qvm_new_apps.quotation_items qi ON qi.quotation_item_id = s.quotation_item_id
        LEFT JOIN qvm_new_apps.vendors v ON v.vendor_id = s.vendor_id
       ORDER BY s.created_at DESC
       LIMIT GREATEST(COALESCE(p_limit, 100), 1)) x), '[]'::jsonb);
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_details(p_quotation_id integer, p_vendor_id integer, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[], p_quotation_vendor_id bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result JSON;
    v_quotation_vendor_ids BIGINT[];
    v_vendor_status INT;
BEGIN
    IF p_quotation_vendor_id IS NOT NULL THEN
      -- Precise, unambiguous scope: exactly the row the caller clicked into. Still verify it
      -- actually belongs to this vendor/quotation so a stale/foreign id can't leak data.
      SELECT array_agg(qv.quotation_vendor_id), MIN(qv.vendor_status)
      INTO v_quotation_vendor_ids, v_vendor_status
      FROM qvm_new_apps.quotation_vendors qv
      WHERE qv.quotation_id = p_quotation_id
        AND qv.vendor_id = p_vendor_id
        AND qv.quotation_vendor_id = p_quotation_vendor_id;
    ELSE
      SELECT array_agg(qv.quotation_vendor_id), MIN(qv.vendor_status)
      INTO v_quotation_vendor_ids, v_vendor_status
      FROM qvm_new_apps.quotation_vendors qv
      WHERE qv.quotation_id = p_quotation_id
        AND qv.vendor_id = p_vendor_id
        AND (p_vendor_branch_ids IS NULL OR qv.vendor_branch_id = ANY(p_vendor_branch_ids));
    END IF;

    SELECT json_build_object(
        'status', 'success',
        'message', 'Quotation details fetched successfully',
        'data', jsonb_build_object(
            'quotation_vendor_id', v_quotation_vendor_ids[1],
            'vendor_status', v_vendor_status,
            'vendor_name', (SELECT v.vendor_name FROM qvm_new_apps.vendors v WHERE v.vendor_id = p_vendor_id),
            'quotation', (
                SELECT jsonb_build_object(
                    'quotation_id', q.quotation_id,
                    'order_number', q.order_number,
                    'plate_number', q.plate_number,
                    'delivery_type', q.delivery_type,
                    'account_manager', q.account_manager,
                    'created_at', q.created_at,
                    'updated_at', q.updated_at
                )
                FROM qvm_new_apps.quotations q
                WHERE q.quotation_id = p_quotation_id
            ),
            'items', (
                SELECT json_agg(t.obj)
                FROM (
                    SELECT DISTINCT ON (qi.quotation_item_id)
                        json_build_object(
                            'quotation_item_id', qi.quotation_item_id,
                            'vin', qi.vin,
                            'main_brand', qi.main_brand,
                            'main_brand_name', main_brand_ld.list_data,
                            'model', qi.model,
                            'part_description', qi.part_description,
                            'part_number', qi.part_number,
                -- The line's part-number changes since this vendor was first sent it, oldest first.
                'part_number_changes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                        'old_part_number', c.old_part_number, 'new_part_number', c.new_part_number,
                        'changed_at', c.changed_at, 'changed_by_role', c.changed_by_role) ORDER BY c.changed_at), '[]'::jsonb)
                    FROM qvm_new_apps.quotation_item_part_number_changes c
                   WHERE c.quotation_item_id = qi.quotation_item_id
                     AND c.changed_at > COALESCE((SELECT min(x.created_at) FROM qvm_new_apps.quotation_vendor_items x
                                                   WHERE x.quotation_item_id = qi.quotation_item_id AND x.vendor_id = p_vendor_id), '-infinity'::timestamptz)),
                            -- The line's part-number changes since this vendor was first sent it, oldest first.
                            'part_number_changes', (SELECT COALESCE(json_agg(json_build_object(
                                    'old_part_number', c.old_part_number, 'new_part_number', c.new_part_number,
                                    'changed_at', c.changed_at, 'changed_by_role', c.changed_by_role) ORDER BY c.changed_at), '[]'::json)
                                FROM qvm_new_apps.quotation_item_part_number_changes c
                               WHERE c.quotation_item_id = qi.quotation_item_id
                                 AND c.changed_at > COALESCE((SELECT min(x.created_at) FROM qvm_new_apps.quotation_vendor_items x
                                                               WHERE x.quotation_item_id = qi.quotation_item_id AND x.vendor_id = p_vendor_id), '-infinity'::timestamptz)),
                            'quantity', qi.quantity,
                            'brand_class', qi.brand_class,
                            'brand_class_name', brand_class_ld.list_data,
                            'part_category', qi.part_category,
                            'part_category_name', part_category_ld.list_data,
                            'part_photo', qi.part_photo,
                            'item_status', qi.item_status,
                            'item_status_name', item_status_ld.list_data,
                            'alternative_part_number', qi.alternative_part_number,
                            'created_at', qi.created_at,
                            'updated_at', qi.updated_at,
                            'vendor_pricing', (
                                SELECT COALESCE(
                                    json_agg(
                                        json_build_object(
                                            'cost_id', qvi2.cost_id,
                                            'cost', qvi2.cost,
                                            'vendor_id', qvi2.vendor_id,
                                            'vendor_item_status', qvi2.vendor_item_status,
                                            -- Where the price came from. A line priced from the vendor's own
                                            -- stock file stays open for the vendor to change.
                                            'price_source', qvi2.price_source,
                                            'discount_percent', qvi2.discount_percent,
                                            'agency_price', qvi2.agency_price,
                                            'sla', qvi2.sla,
                                            'best_cost', qvi2.best_cost,
                                            'available_quantity', qvi2.available_quantity,
                                            'quotation_vendor_id', qvi2.quotation_vendor_id,
                                            'available_brand_class', qvi2.available_brand_class,
                                            'alternative_part_number', qvi2.alternative_part_number,
                                            'created_at', qvi2.created_at,
                                            'updated_at', qvi2.updated_at,
                                            'available_brand_id', qvi2.available_brand_id,
                                            'available_brand_name', avail_brand_ld.list_data,
                                            'origin_country_id', qvi2.origin_country_id,
                                            'origin_country_name_en', avail_origin.name_en,
                                            'origin_country_name_ar', avail_origin.name_ar,
                                            'note', qvi2.note,
                                            'files', COALESCE(qvi2.files, '[]'::jsonb),
                                            'improvement_requested_at', qvi2.improvement_requested_at,
                                            'improvement_note', qvi2.improvement_note,
                                            'previous_cost', qvi2.previous_cost,
                                            -- The vendor's alternatives for this line, loaded with
                                            -- the line itself so the البدائل badge has its count on
                                            -- first paint instead of after a second round trip.
                                            'alternatives', qvm_new_apps.alternatives_of_cost(qvi2.cost_id),
                                            'item_notes', (
                                                SELECT json_agg(
                                                    json_build_object(
                                                        'note_description', n.note_description,
                                                        'note_attachment', n.note_attachment,
                                                        'created_at', n.created_at,
                                                        'user_name', u.user_name
                                                    )
                                                    ORDER BY n.created_at DESC
                                                )
                                                FROM qvm_new_apps.notes n
                                                LEFT JOIN qvm_new_apps.user_data u
                                                  ON u.user_id = n.user_id
                                                WHERE n.note_type = 'quotation_vendor_item'
                                                  AND n.type_id = qvi2.cost_id
                                                  AND n.is_internal = FALSE
                                            )
                                        )
                                    ),
                                    '[]'::json
                                )
                                FROM qvm_new_apps.quotation_vendor_items qvi2
                                LEFT JOIN qvm_new_apps.list_data avail_brand_ld
                                       ON avail_brand_ld.list_data_id = qvi2.available_brand_id
                                LEFT JOIN qvm_new_apps.origin_countries avail_origin
                                       ON avail_origin.origin_country_id = qvi2.origin_country_id
                                WHERE qvi2.quotation_item_id = qi.quotation_item_id
                                  AND qvi2.vendor_id = p_vendor_id
                                  AND qvi2.quotation_vendor_id = ANY(v_quotation_vendor_ids)
                            )
                        ) AS obj
                    FROM qvm_new_apps.quotation_vendor_items qvi
                    JOIN qvm_new_apps.quotation_items qi
                      ON qi.quotation_item_id = qvi.quotation_item_id
                    LEFT JOIN qvm_new_apps.list_data main_brand_ld
                           ON qi.main_brand = main_brand_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data brand_class_ld
                           ON qi.brand_class = brand_class_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data part_category_ld
                           ON qi.part_category = part_category_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data item_status_ld
                           ON qi.item_status = item_status_ld.list_data_id
                    WHERE qvi.vendor_id = p_vendor_id
                      AND qvi.quotation_vendor_id = ANY(v_quotation_vendor_ids)
                    ORDER BY qi.quotation_item_id
                ) t
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;
