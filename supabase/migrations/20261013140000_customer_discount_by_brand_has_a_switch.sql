-- Customer discount by brand, edited inside the add / edit customer form, with a switch.
-- The switch keeps the rates but stops them applying: an offer to a customer whose brand discounts
-- are off starts without an agreed discount.

alter table qvm_new_apps.end_customers
  add column if not exists brand_discounts_enabled boolean not null default true;
comment on column qvm_new_apps.end_customers.brand_discounts_enabled is
  'Whether the customer''s discounts by brand (end_customer_discounts) apply to the offers sent to them.';

-- Everything the editor shows: the switch and the rows.
create or replace function qvm_new_apps.get_end_customer_discount_settings(p_end_customer_id bigint)
returns jsonb language sql stable security definer set search_path to 'qvm_new_apps', 'public' as $$
  select case when not qvm_new_apps.is_qparts_team() then jsonb_build_object('enabled', true, 'rows', '[]'::jsonb)
         else jsonb_build_object(
           'enabled', coalesce((select ec.brand_discounts_enabled from qvm_new_apps.end_customers ec where ec.end_customer_id = p_end_customer_id), true),
           'rows', qvm_new_apps.list_end_customer_discounts(p_end_customer_id)) end;
$$;
grant execute on function qvm_new_apps.get_end_customer_discount_settings(bigint) to authenticated, service_role;

-- Saving takes the switch too; a null switch leaves it as it is.
drop function if exists qvm_new_apps.set_end_customer_discounts(bigint, jsonb);
create or replace function qvm_new_apps.set_end_customer_discounts(p_end_customer_id bigint, p_rows jsonb, p_enabled boolean default null)
returns jsonb language plpgsql security definer set search_path to 'qvm_new_apps', 'public' as $$
declare v_n integer;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'Only the Qparts team can set agreed discounts');
  end if;
  if not exists (select 1 from qvm_new_apps.end_customers where end_customer_id = p_end_customer_id) then
    return jsonb_build_object('status', false, 'message', 'Unknown customer');
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x
              where coalesce((x->>'discount_percent')::numeric, -1) not between 0 and 90) then
    return jsonb_build_object('status', false, 'message', 'A discount must be between 0 and 90%');
  end if;
  if (select count(*) from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x)
     <> (select count(distinct coalesce(nullif(x->>'car_brand_id', '')::int, 0)) from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x) then
    return jsonb_build_object('status', false, 'message', 'Each brand can have one discount only');
  end if;

  delete from qvm_new_apps.end_customer_discounts where end_customer_id = p_end_customer_id;
  insert into qvm_new_apps.end_customer_discounts (end_customer_id, car_brand_id, discount_percent, updated_by)
  select p_end_customer_id, nullif(x->>'car_brand_id', '')::int, round((x->>'discount_percent')::numeric, 2), auth.uid()
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x;
  get diagnostics v_n = row_count;

  if p_enabled is not null then
    update qvm_new_apps.end_customers set brand_discounts_enabled = p_enabled where end_customer_id = p_end_customer_id;
  end if;

  return jsonb_build_object('status', true, 'rows', v_n,
                            'data', qvm_new_apps.list_end_customer_discounts(p_end_customer_id),
                            'enabled', (select brand_discounts_enabled from qvm_new_apps.end_customers where end_customer_id = p_end_customer_id));
end $$;
grant execute on function qvm_new_apps.set_end_customer_discounts(bigint, jsonb, boolean) to authenticated, service_role;

-- The offer draft applies an agreed rate only while the switch is on.
CREATE OR REPLACE FUNCTION qvm_new_apps.customer_offer_draft(p_quotation_id bigint, p_item_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_customer bigint;
  v_brand    integer;
  v_agreed   jsonb;
  v_last     jsonb;
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'Only the Qparts team can prepare a customer offer');
  end if;
  select q.end_customer_id into v_customer from qvm_new_apps.quotations q where q.quotation_id = p_quotation_id;
  if not found then return jsonb_build_object('status', false, 'message', 'Unknown order'); end if;

  select qi.main_brand into v_brand from qvm_new_apps.quotation_items qi
   where qi.quotation_id = p_quotation_id and qi.main_brand is not null
   order by qi.quotation_item_id limit 1;

  -- The brand's own agreement first, then the customer's all-brands rate.
  select jsonb_build_object('discount_percent', d.discount_percent,
                            'car_brand_id', d.car_brand_id,
                            'car_brand_name', ld.list_data,
                            'scope', case when d.car_brand_id is null then 'all_brands' else 'brand' end)
    into v_agreed
    from qvm_new_apps.end_customer_discounts d
    left join qvm_new_apps.list_data ld on ld.list_data_id = d.car_brand_id
   where d.end_customer_id = v_customer
     -- A customer whose brand discounts are switched off has no agreement to apply.
     and exists (select 1 from qvm_new_apps.end_customers ec0 where ec0.end_customer_id = v_customer and ec0.brand_discounts_enabled)
     and (d.car_brand_id = v_brand or d.car_brand_id is null)
   order by (d.car_brand_id is null) asc
   limit 1;

  -- The last offer this customer received sets the defaults: channel, recipient, format, what shows.
  select jsonb_build_object('channel', o.channel, 'recipient', o.recipient, 'format', o.format,
                            'validity_days', o.validity_days, 'discount_mode', o.discount_mode,
                            'base_discount', o.base_discount,
                            'show', jsonb_build_object('part_number', o.show_part_number, 'alternatives', o.show_alternatives,
                                                       'discount', o.show_discount, 'lead_time', o.show_lead_time,
                                                       'notes', o.show_notes, 'photos', o.show_photos))
    into v_last
    from qvm_new_apps.quotation_approval_offers o
    join qvm_new_apps.quotation_approval_rounds r on r.approval_round_id = o.approval_round_id
   where v_customer is not null and r.end_customer_id = v_customer
   order by o.sent_at desc limit 1;

  return jsonb_build_object(
    'status', true,
    'order', (select jsonb_build_object(
                'quotation_id', q.quotation_id, 'order_number', q.order_number, 'plate_number', q.plate_number,
                'workshop', (select cb.branch_name from qvm_new_apps.quotation_items qi
                               join qvm_new_apps.client_branches cb on cb.customer_id = qi.customer_id
                              where qi.quotation_id = q.quotation_id limit 1),
                'vehicle', (select jsonb_build_object('brand', ld.list_data, 'model', qi.model, 'year', qi.year)
                              from qvm_new_apps.quotation_items qi
                              left join qvm_new_apps.list_data ld on ld.list_data_id = qi.main_brand
                             where qi.quotation_id = q.quotation_id
                             order by (qi.main_brand is null), qi.quotation_item_id limit 1))
                from qvm_new_apps.quotations q where q.quotation_id = p_quotation_id),
    'customer', (select jsonb_build_object(
                   'end_customer_id', ec.end_customer_id, 'customer_kind', ec.customer_kind,
                   'name', coalesce(ec.name, ic.name), 'email', ec.email, 'phone', ec.phone,
                   'contact_person', ec.contact_person,
                   'portal_users', coalesce((select jsonb_agg(ud.user_name order by ud.user_name)
                                               from qvm_new_apps.end_customer_users eu
                                               join qvm_new_apps.user_data ud on ud.user_id = eu.user_id and ud.deleted_at is null
                                              where eu.end_customer_id = ec.end_customer_id), '[]'::jsonb))
                   from qvm_new_apps.end_customers ec
                   left join qvm_new_apps.insurance_companies ic on ic.id = ec.insurance_company_id
                  where ec.end_customer_id = v_customer),
    'email_recipients', qvm_new_apps.approval_recipients(p_quotation_id, 'client'),
    'agreed_discount', v_agreed,
    'last_offer', v_last,
    'pending_round', (select jsonb_build_object('approval_round_id', r.approval_round_id, 'sent_at', r.sent_at)
                        from qvm_new_apps.quotation_approval_rounds r
                       where r.quotation_id = p_quotation_id and r.audience = 'client' and r.status = 'pending'),
    'attachments', coalesce((
       select jsonb_agg(jsonb_build_object(
                'attachment_id', a.attachment_id, 'name', coalesce(a.file_name, 'file'), 'url', a.file_url,
                'mime_type', a.mime_type, 'size', a.file_size, 'source', a.source, 'created_at', a.created_at,
                'vendor_name', v.vendor_name) order by a.created_at desc)
         from qvm_new_apps.quotation_attachments a
         left join qvm_new_apps.vendors v on v.vendor_id = a.vendor_id
        where a.quotation_id = p_quotation_id and coalesce(a.file_url, '') <> ''), '[]'::jsonb),
    'lines', coalesce((
       select jsonb_agg(jsonb_build_object(
                'quotation_item_id', qi.quotation_item_id,
                'part_description', qi.part_description,
                'part_number', qi.part_number,
                'quantity', qi.quantity,
                -- The same customer price the round snapshots: the pricing page's customer price,
                -- else the before-discount price of the vendor picked for the customer, else the
                -- offer bought from.
                'price_before_discount', coalesce(nullif(qi.agency_price, 0), best.customer_before_price),
                'lead_days', nullif(regexp_replace(coalesce(best.sla, ''), '[^0-9]', '', 'g'), '')::int,
                'photos', case when coalesce(qi.part_photo, '') like '[%' then jsonb_array_length(qi.part_photo::jsonb)
                               when coalesce(qi.part_photo, '') <> '' then 1 else 0 end,
                'photo_urls', case when coalesce(qi.part_photo, '') like '[%' then qi.part_photo::jsonb
                                   when coalesce(qi.part_photo, '') <> '' then jsonb_build_array(qi.part_photo)
                                   else '[]'::jsonb end,
                'chosen_alternative_id', best.chosen_alternative_id,
                'alternatives', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'alternative_id', a.alternative_id, 'part_number', a.part_number,
                            'brand_name', br.list_data, 'brand_class_name', bc.list_data,
                            'unit_price', a.unit_price, 'delivery_days', a.delivery_days, 'note', a.note)
                            order by a.alternative_id)
                     from qvm_new_apps.quotation_vendor_item_alternatives a
                     left join qvm_new_apps.list_data bc on bc.list_data_id = a.brand_class
                     left join qvm_new_apps.list_data br on br.list_data_id = a.brand_id
                    where (a.cost_id = best.cost_id or (a.source = 'qparts' and a.quotation_item_id = qi.quotation_item_id))
                      and a.visible_to_workshop), '[]'::jsonb)
              ) order by qi.quotation_item_id)
         from qvm_new_apps.quotation_items qi
         left join lateral (
           select qvi.cost_id, qvi.sla, qvi.chosen_alternative_id,
                  coalesce(cp.agency_price, qvi.agency_price) as customer_before_price
             from qvm_new_apps.quotation_vendor_items qvi
             left join qvm_new_apps.quotation_vendor_items cp on cp.cost_id = qi.customer_price_cost_id
            where qvi.quotation_item_id = qi.quotation_item_id and qvi.cost is not null and qvi.cost > 0
            order by (qvi.cost_id = qi.selected_cost_id) desc nulls last, qvi.best_cost desc, qvi.cost asc
            limit 1) best on true
        where qi.quotation_id = p_quotation_id
          and (p_item_ids is null or qi.quotation_item_id = any(p_item_ids))
          and not (qi.quotation_item_id = any(qvm_new_apps.approved_item_ids(p_quotation_id, 'client')))
          and qi.item_status not in (select ld.list_data_id from qvm_new_apps.list_data ld
                                      where ld.list_id = 3
                                        and ld.list_data in ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))
       ), '[]'::jsonb));
end $function$;

notify pgrst, 'reload schema';
