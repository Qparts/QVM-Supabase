-- Sending a quotation to the customer is now a prepared offer, not a single click.
--
-- The pricing page opens a three-step screen before "Request customer approval" sends anything:
--   1. prepare the offer — discount (as agreed with the customer / a custom rate / none), per line
--      discount, lead time and note, which lines and which alternatives go, what the customer sees
--      (part number, alternatives, discount columns, lead time, notes, photos) and which files go
--      with it;
--   2. channel and recipient — email, WhatsApp or the customer portal, the document format, how long
--      the offer is valid, the claim number and the message;
--   3. preview exactly what the customer will see, then send.
--
-- What this migration adds:
--   end_customer_discounts        the discount agreed with a customer, per car brand (or for all)
--   quotation_approval_offers     the offer settings of a customer round (one per round)
--   quotation_approval_items.*    per-line before-discount price, discount, lead time, note and the
--                                 alternatives the customer may see
--   customer_offer_draft()        everything the screen needs, prefilled
--   send_customer_offer()         opens / extends the customer round with those settings
--   record_customer_offer_delivery()  what was delivered where (document link, channel outcome)
--   approval_lines / get_approval_round_by_token / decide_approval_items honour the offer.

-- 1. Agreed discounts -----------------------------------------------------------------------------
create table if not exists qvm_new_apps.end_customer_discounts (
  discount_id      bigserial primary key,
  end_customer_id  bigint not null references qvm_new_apps.end_customers(end_customer_id) on delete cascade,
  car_brand_id     integer,          -- list_data (car_brand); null = every brand
  discount_percent numeric(5,2) not null check (discount_percent >= 0 and discount_percent <= 90),
  updated_by       uuid default auth.uid(),
  updated_at       timestamptz not null default now()
);
comment on table qvm_new_apps.end_customer_discounts is
  'The discount agreed with an end customer, per car brand; a row with no brand applies to every brand without its own.';
create unique index if not exists end_customer_discounts_one_per_brand
  on qvm_new_apps.end_customer_discounts (end_customer_id, coalesce(car_brand_id, 0));
alter table qvm_new_apps.end_customer_discounts enable row level security;
drop policy if exists end_customer_discounts_team_read on qvm_new_apps.end_customer_discounts;
create policy end_customer_discounts_team_read on qvm_new_apps.end_customer_discounts
  for select to authenticated using (qvm_new_apps.is_qparts_team());
grant select on qvm_new_apps.end_customer_discounts to authenticated;
grant all on qvm_new_apps.end_customer_discounts to service_role;

create or replace function qvm_new_apps.list_end_customer_discounts(p_end_customer_id bigint)
returns jsonb language sql stable security definer set search_path to 'qvm_new_apps', 'public' as $$
  select case when not qvm_new_apps.is_qparts_team() then '[]'::jsonb else coalesce((
    select jsonb_agg(jsonb_build_object(
             'discount_id', d.discount_id, 'car_brand_id', d.car_brand_id,
             'car_brand_name', ld.list_data, 'discount_percent', d.discount_percent,
             'updated_at', d.updated_at) order by d.car_brand_id nulls first, ld.list_data)
      from qvm_new_apps.end_customer_discounts d
      left join qvm_new_apps.list_data ld on ld.list_data_id = d.car_brand_id
     where d.end_customer_id = p_end_customer_id), '[]'::jsonb) end;
$$;

-- Replaces the customer's whole list: what the editor shows is what is stored.
create or replace function qvm_new_apps.set_end_customer_discounts(p_end_customer_id bigint, p_rows jsonb)
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
  return jsonb_build_object('status', true, 'rows', v_n,
                            'data', qvm_new_apps.list_end_customer_discounts(p_end_customer_id));
end $$;

grant execute on function qvm_new_apps.list_end_customer_discounts(bigint) to authenticated, service_role;
grant execute on function qvm_new_apps.set_end_customer_discounts(bigint, jsonb) to authenticated, service_role;

-- 2. Per-line offer columns -----------------------------------------------------------------------
alter table qvm_new_apps.quotation_approval_items
  add column if not exists price_before_discount numeric,
  add column if not exists discount_percent      numeric(5,2),
  add column if not exists lead_days             integer,
  add column if not exists customer_note         text,
  add column if not exists shown_alternative_ids bigint[];
comment on column qvm_new_apps.quotation_approval_items.price_before_discount is
  'Customer rounds sent as a prepared offer: the customer price before the offer''s discount; customer_price then holds the discounted price.';
comment on column qvm_new_apps.quotation_approval_items.shown_alternative_ids is
  'The alternatives the customer may see and pick on this line; null = every alternative visible to the workshop (rounds sent before offers existed).';

-- 3. The offer ------------------------------------------------------------------------------------
create table if not exists qvm_new_apps.quotation_approval_offers (
  offer_id          bigserial primary key,
  approval_round_id bigint not null unique references qvm_new_apps.quotation_approval_rounds(approval_round_id) on delete cascade,
  quotation_id      bigint not null,
  discount_mode     text not null default 'none' check (discount_mode in ('agreed', 'custom', 'none')),
  base_discount     numeric(5,2) not null default 0,
  show_part_number  boolean not null default true,
  show_alternatives boolean not null default true,
  show_discount     boolean not null default true,
  show_lead_time    boolean not null default true,
  show_notes        boolean not null default true,
  show_photos       boolean not null default true,
  attachments       jsonb not null default '[]'::jsonb,  -- [{name, url, kind}]
  channel           text not null default 'email' check (channel in ('email', 'whatsapp', 'portal')),
  recipient         text,
  format            text not null default 'pdf' check (format in ('pdf', 'excel', 'link')),
  validity_days     integer not null default 14 check (validity_days between 1 and 90),
  claim_number      text,
  subject           text,
  message           text,
  document_url      text,                               -- the generated PDF / Excel
  delivery          jsonb not null default '{}'::jsonb,  -- what the channel answered
  sent_by           uuid default auth.uid(),
  sent_at           timestamptz not null default now()
);
comment on table qvm_new_apps.quotation_approval_offers is
  'How a customer approval round was put to the customer: discount, what they see, attachments, channel, recipient, validity and message.';
create index if not exists quotation_approval_offers_quotation_idx on qvm_new_apps.quotation_approval_offers (quotation_id);
alter table qvm_new_apps.quotation_approval_offers enable row level security;
drop policy if exists quotation_approval_offers_team_read on qvm_new_apps.quotation_approval_offers;
create policy quotation_approval_offers_team_read on qvm_new_apps.quotation_approval_offers
  for select to authenticated using (qvm_new_apps.is_qparts_team());
grant select on qvm_new_apps.quotation_approval_offers to authenticated;
grant all on qvm_new_apps.quotation_approval_offers to service_role;

-- 4. The draft: everything the screen needs, prefilled -------------------------------------------
create or replace function qvm_new_apps.customer_offer_draft(p_quotation_id bigint, p_item_ids bigint[] default null)
returns jsonb language plpgsql stable security definer set search_path to 'qvm_new_apps', 'public' as $$
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
end $$;
grant execute on function qvm_new_apps.customer_offer_draft(bigint, bigint[]) to authenticated, service_role;

-- 5. Sending ------------------------------------------------------------------------------------
create or replace function qvm_new_apps.send_customer_offer(p_quotation_id bigint, p_offer jsonb)
returns jsonb language plpgsql security definer set search_path to 'qvm_new_apps', 'public' as $$
declare
  v_ids      bigint[];
  v_res      jsonb;
  v_round    jsonb;
  v_round_id bigint;
  v_mode     text := coalesce(nullif(p_offer->>'discount_mode', ''), 'none');
  v_base     numeric := least(greatest(coalesce(nullif(p_offer->>'base_discount', '')::numeric, 0), 0), 90);
  v_validity integer := least(greatest(coalesce(nullif(p_offer->>'validity_days', '')::int, 14), 1), 90);
  v_channel  text := coalesce(nullif(p_offer->>'channel', ''), 'email');
  v_format   text := coalesce(nullif(p_offer->>'format', ''), 'pdf');
  v_show     jsonb := coalesce(p_offer->'show', '{}'::jsonb);
  v_total    numeric;
  v_before   numeric;
  v_items    integer;
begin
  if not qvm_new_apps.is_qparts_team() then
    raise exception 'Only the Qparts team can send an offer to the customer';
  end if;
  if v_mode not in ('agreed', 'custom', 'none') then raise exception 'Unknown discount mode: %', v_mode; end if;
  if v_channel not in ('email', 'whatsapp', 'portal') then raise exception 'Unknown channel: %', v_channel; end if;
  if v_format not in ('pdf', 'excel', 'link') then raise exception 'Unknown format: %', v_format; end if;
  if v_channel <> 'portal' and coalesce(btrim(p_offer->>'recipient'), '') = '' then
    return jsonb_build_object('status', 'error', 'message', 'A recipient is required for this channel');
  end if;

  select array_agg(distinct (x->>'quotation_item_id')::bigint) into v_ids
    from jsonb_array_elements(coalesce(p_offer->'lines', '[]'::jsonb)) x
   where nullif(x->>'quotation_item_id', '') is not null;
  if v_ids is null or cardinality(v_ids) = 0 then
    return jsonb_build_object('status', 'error', 'message', 'Pick at least one line to send');
  end if;

  -- The round itself is opened (or extended) by the one sender everything else uses, so the rules
  -- on which lines may travel stay in one place.
  v_res := qvm_new_apps.send_quotation_for_approval(p_quotation_id, array['client'], v_ids);
  v_round := v_res->'rounds'->0;
  if v_round is null or v_round->>'status' = 'nothing_to_send' then
    return jsonb_build_object('status', 'nothing_to_send');
  end if;
  v_round_id := (v_round->>'approval_round_id')::bigint;

  -- The lines as prepared. customer_price was just snapshotted before discount; it becomes the
  -- price the customer is asked to approve, and the before-discount price is kept beside it.
  update qvm_new_apps.quotation_approval_items ai
     set price_before_discount = ai.customer_price,
         discount_percent = case when v_mode = 'none' then 0
                                 else least(greatest(coalesce(nullif(x->>'discount_percent', '')::numeric, v_base), 0), 90) end,
         customer_price = case when ai.customer_price is null then null
                               else round(ai.customer_price * (1 - (case when v_mode = 'none' then 0
                                      else least(greatest(coalesce(nullif(x->>'discount_percent', '')::numeric, v_base), 0), 90) end) / 100), 2) end,
         lead_days = nullif(x->>'lead_days', '')::int,
         customer_note = nullif(btrim(coalesce(x->>'note', '')), ''),
         shown_alternative_ids = case when jsonb_typeof(x->'shown_alternative_ids') = 'array'
                                      then array(select (e)::bigint from jsonb_array_elements_text(x->'shown_alternative_ids') e)
                                      else '{}'::bigint[] end,
         -- The customer is asked about the part, or an alternative they were shown — never one
         -- the offer hides from them.
         chosen_alternative_id = case when ai.chosen_alternative_id is not null
                                       and jsonb_typeof(x->'shown_alternative_ids') = 'array'
                                       and (x->'shown_alternative_ids') @> to_jsonb(ai.chosen_alternative_id)
                                      then ai.chosen_alternative_id else null end
    from jsonb_array_elements(p_offer->'lines') x
   where ai.approval_round_id = v_round_id
     and ai.quotation_item_id = (x->>'quotation_item_id')::bigint
     and ai.decision = 'pending';

  select coalesce(sum(coalesce(ai.customer_price, 0) * coalesce(ai.quantity, 1)), 0),
         coalesce(sum(coalesce(ai.price_before_discount, ai.customer_price, 0) * coalesce(ai.quantity, 1)), 0),
         count(*)
    into v_total, v_before, v_items
    from qvm_new_apps.quotation_approval_items ai
   where ai.approval_round_id = v_round_id and ai.decision <> 'cancelled';

  update qvm_new_apps.quotation_approval_rounds r
     set total_amount = v_total,
         -- The offer's validity is the link's life.
         token_expires_at = now() + make_interval(days => v_validity)
   where r.approval_round_id = v_round_id;

  insert into qvm_new_apps.quotation_approval_offers as o
    (approval_round_id, quotation_id, discount_mode, base_discount,
     show_part_number, show_alternatives, show_discount, show_lead_time, show_notes, show_photos,
     attachments, channel, recipient, format, validity_days, claim_number, subject, message, sent_by, sent_at)
  values
    (v_round_id, p_quotation_id, v_mode, case when v_mode = 'none' then 0 else v_base end,
     coalesce((v_show->>'part_number')::boolean, true), coalesce((v_show->>'alternatives')::boolean, true),
     coalesce((v_show->>'discount')::boolean, true) and v_mode <> 'none', coalesce((v_show->>'lead_time')::boolean, true),
     coalesce((v_show->>'notes')::boolean, true), coalesce((v_show->>'photos')::boolean, true),
     coalesce(p_offer->'attachments', '[]'::jsonb), v_channel, nullif(btrim(coalesce(p_offer->>'recipient', '')), ''),
     v_format, v_validity, nullif(btrim(coalesce(p_offer->>'claim_number', '')), ''),
     nullif(btrim(coalesce(p_offer->>'subject', '')), ''), nullif(btrim(coalesce(p_offer->>'message', '')), ''),
     auth.uid(), now())
  on conflict (approval_round_id) do update set
     discount_mode = excluded.discount_mode, base_discount = excluded.base_discount,
     show_part_number = excluded.show_part_number, show_alternatives = excluded.show_alternatives,
     show_discount = excluded.show_discount, show_lead_time = excluded.show_lead_time,
     show_notes = excluded.show_notes, show_photos = excluded.show_photos,
     attachments = excluded.attachments, channel = excluded.channel, recipient = excluded.recipient,
     format = excluded.format, validity_days = excluded.validity_days, claim_number = excluded.claim_number,
     subject = excluded.subject, message = excluded.message, sent_by = excluded.sent_by, sent_at = excluded.sent_at,
     document_url = null, delivery = '{}'::jsonb;

  return jsonb_build_object(
    'status', 'success',
    'approval_round_id', v_round_id,
    'access_token', v_round->>'access_token',
    'items', v_items,
    'total_before_discount', v_before,
    'total_amount', v_total,
    'expires_at', (select token_expires_at from qvm_new_apps.quotation_approval_rounds where approval_round_id = v_round_id));
end $$;
grant execute on function qvm_new_apps.send_customer_offer(bigint, jsonb) to authenticated, service_role;

-- What the channel did with it: the generated document and the channel's answer.
create or replace function qvm_new_apps.record_customer_offer_delivery(p_approval_round_id bigint, p_document_url text, p_delivery jsonb)
returns jsonb language plpgsql security definer set search_path to 'qvm_new_apps', 'public' as $$
begin
  if not qvm_new_apps.is_qparts_team() then
    return jsonb_build_object('status', false, 'message', 'Only the Qparts team can record a delivery');
  end if;
  update qvm_new_apps.quotation_approval_offers
     set document_url = coalesce(nullif(p_document_url, ''), document_url),
         delivery = coalesce(delivery, '{}'::jsonb) || coalesce(p_delivery, '{}'::jsonb) || jsonb_build_object('recorded_at', now())
   where approval_round_id = p_approval_round_id;
  if not found then return jsonb_build_object('status', false, 'message', 'No offer for this round'); end if;
  return jsonb_build_object('status', true);
end $$;
grant execute on function qvm_new_apps.record_customer_offer_delivery(bigint, text, jsonb) to authenticated, service_role;

-- 6. The customer's view honours the offer -------------------------------------------------------
CREATE OR REPLACE FUNCTION qvm_new_apps.approval_lines(p_quotation_id bigint, p_audience text, p_round_id bigint, p_round_status text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               -- NULL for a line never put to this audience: there is nothing to answer on it.
               'approval_item_id',  li.approval_item_id,
               'quotation_item_id', qi.quotation_item_id,
               'part_number',       CASE WHEN p_audience = 'client' AND off.show_part_number IS FALSE THEN NULL ELSE qi.part_number END,
               'part_description',  qi.part_description,
               -- The line itself, so the table this feeds can stand in for the order's item list:
               -- where the part is in its life, its photos, how many notes are on it, its class.
               'item_status',       ldst.list_data,
               'item_status_id',    qi.item_status,
               'part_photo',        CASE WHEN p_audience = 'client' AND off.show_photos IS FALSE THEN NULL ELSE qi.part_photo END,
               'brand_class',       ld_bc.list_data,
               'notes_count',       (SELECT COUNT(*)::int FROM qvm_new_apps.notes n
                                      WHERE n.note_type = 'quotation_items'
                                        AND n.type_id = qi.quotation_item_id
                                        AND n.is_internal = FALSE),
               -- What the vendor said and showed on the offer this line is priced from. The
               -- workshop's business; the customer is not shown the vendor's side.
               'vendor_note',  CASE WHEN p_audience = 'workshop' THEN COALESCE(qvi.note, bq.note) END,
               'vendor_files', CASE WHEN p_audience = 'workshop' THEN COALESCE(qvi.files, bq.files, '[]'::jsonb) ELSE '[]'::jsonb END,
               'quantity',          COALESCE(li.quantity, qi.quantity),
               'delivery_days',     CASE WHEN p_audience = 'client' AND off.show_lead_time IS FALSE THEN NULL
                                 WHEN p_audience = 'client' AND li.lead_days IS NOT NULL THEN li.lead_days::text
                                 ELSE COALESCE(qvi.sla, bq.sla) END,
               -- A customer round sent as a prepared offer: the price before its discount, the
               -- discount, and the buyer's note — each only when the offer shows it.
               'price_before_discount', CASE WHEN p_audience = 'client' AND off.show_discount THEN li.price_before_discount END,
               'discount_percent',      CASE WHEN p_audience = 'client' AND off.show_discount THEN li.discount_percent END,
               'customer_note',         CASE WHEN p_audience = 'client' AND off.show_notes IS NOT FALSE THEN li.customer_note END,
               -- The one number this audience is entitled to, under one name either way. From the
               -- round's snapshot when the line was sent; when it was not, from the pricing page's
               -- تسعيرك column and nothing else — سعر الجملة (price_before_vat) for the workshop,
               -- سعر العميل (agency_price) for the customer. A vendor's offer is the pricing team's
               -- material, not a price: until they set one, the line has none.
               'unit_price', CASE WHEN p_audience = 'workshop'
                                  THEN COALESCE(li.wholesale_price, NULLIF(qi.price_before_vat, 0))
                                  ELSE COALESCE(li.customer_price, NULLIF(qi.agency_price, 0)) END,
               'customer_price_reference',
                 CASE WHEN p_audience = 'workshop'
                      THEN COALESCE(li.customer_price, NULLIF(qi.agency_price, 0)) END,
               -- Where this line stands with THIS audience, whichever round it was in.
               'sent',              li.approval_item_id IS NOT NULL,
               'line_round_id',     li.approval_round_id,
               'line_round_status', lr.status,
               -- Only a line in the currently open request can be answered.
               'actionable',        li.approval_round_id = p_round_id AND p_round_status = 'pending',
               'decision',          COALESCE(li.decision, 'pending'),
               'reason',            li.reason,
               -- The choice standing on the line: the approval's when it was sent; before that, the
               -- one on the vendor line — only when the workshop is allowed to see it.
               'chosen_alternative_id',
                 CASE WHEN li.approval_item_id IS NOT NULL AND lr.status = 'pending' THEN li.chosen_alternative_id
                      ELSE (SELECT a.alternative_id FROM qvm_new_apps.quotation_vendor_item_alternatives a
                             WHERE a.alternative_id = COALESCE(qvi.chosen_alternative_id, bq.chosen_alternative_id)
                               AND a.visible_to_workshop) END,
               'options', COALESCE((
                 SELECT jsonb_agg(jsonb_build_object(
                          'alternative_id', a.alternative_id,
                          'source',         a.source,
                          'part_number',    a.part_number,
                          'brand_class_name', bc.list_data,
                          'brand_name',     br.list_data,
                          'origin', COALESCE(oc.name_ar, oc.name_en),
                          'unit_price',     CASE WHEN p_audience = 'client' AND li.discount_percent IS NOT NULL AND a.unit_price IS NOT NULL
                                               THEN round(a.unit_price * (1 - li.discount_percent / 100), 2)
                                               ELSE a.unit_price END,
                          'price_before_discount', CASE WHEN p_audience = 'client' AND off.show_discount THEN a.unit_price END,
                          'available_quantity', a.available_quantity,
                          'delivery_days',  a.delivery_days,
                          'note',           a.note,
                          'photos',         a.photos) ORDER BY a.alternative_id)
                   FROM qvm_new_apps.quotation_vendor_item_alternatives a
                   LEFT JOIN qvm_new_apps.list_data bc ON bc.list_data_id = a.brand_class
                   LEFT JOIN qvm_new_apps.list_data br ON br.list_data_id = a.brand_id
                   LEFT JOIN qvm_new_apps.origin_countries oc ON oc.origin_country_id = a.origin_country_id
                  WHERE (a.cost_id = COALESCE(li.cost_id, bq.cost_id)
                         OR (a.source = 'qparts' AND a.quotation_item_id = qi.quotation_item_id))
                    AND a.visible_to_workshop
                    -- The customer sees only the alternatives the offer shows them.
                    AND (p_audience <> 'client' OR off.show_alternatives IS NOT FALSE)
                    AND (p_audience <> 'client' OR li.shown_alternative_ids IS NULL OR a.alternative_id = ANY(li.shown_alternative_ids))), '[]'::jsonb)
             ) ORDER BY qi.quotation_item_id)
        FROM qvm_new_apps.quotation_items qi
        -- The line's most recent appearance in any round for this audience.
        LEFT JOIN LATERAL (
          SELECT ai.*
            FROM qvm_new_apps.quotation_approval_items ai
            JOIN qvm_new_apps.quotation_approval_rounds ar ON ar.approval_round_id = ai.approval_round_id
           WHERE ai.quotation_item_id = qi.quotation_item_id
             AND ar.quotation_id = p_quotation_id
             AND ar.audience = p_audience
           ORDER BY ai.approval_round_id DESC
           LIMIT 1
        ) li ON true
        LEFT JOIN qvm_new_apps.quotation_approval_rounds lr ON lr.approval_round_id = li.approval_round_id
        LEFT JOIN qvm_new_apps.quotation_approval_offers off ON off.approval_round_id = li.approval_round_id
        LEFT JOIN qvm_new_apps.quotation_vendor_items qvi ON qvi.cost_id = li.cost_id
        -- For a line never sent: the offer it would be priced from today — the pricing team's pick
        -- when they made one, otherwise the cheapest, the same order the senders use.
        LEFT JOIN LATERAL (
          SELECT v.cost_id, v.cost, v.agency_price, v.sla, v.chosen_alternative_id, v.note, v.files
            FROM qvm_new_apps.quotation_vendor_items v
           WHERE v.quotation_item_id = qi.quotation_item_id
             AND v.cost IS NOT NULL AND v.cost > 0
           ORDER BY (v.cost_id = qi.selected_cost_id) DESC NULLS LAST, v.best_cost DESC, v.cost ASC
           LIMIT 1
        ) bq ON true
        LEFT JOIN qvm_new_apps.quotation_vendor_item_alternatives bch ON bch.alternative_id = bq.chosen_alternative_id
        -- The offer the pricing team picked for the customer price, when they picked one.
        LEFT JOIN qvm_new_apps.quotation_vendor_items cp ON cp.cost_id = qi.customer_price_cost_id
        LEFT JOIN qvm_new_apps.list_data ldst ON ldst.list_data_id = qi.item_status
        LEFT JOIN qvm_new_apps.list_data ld_bc ON ld_bc.list_data_id = qi.brand_class
       WHERE qi.quotation_id = p_quotation_id
         -- Suggested parts are not part of the order until somebody says so; cancelled ones are gone.
         AND qi.item_status NOT IN (
           SELECT ld.list_data_id FROM qvm_new_apps.list_data ld
            WHERE ld.list_id = 3
              AND ld.list_data IN ('Added by Vendor', 'Pending Workshop Approval', 'Cancelled'))), '[]'::jsonb);
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_approval_round_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  r record;
BEGIN
  SELECT * INTO r FROM qvm_new_apps.quotation_approval_rounds
   WHERE access_token = p_token;

  IF r IS NULL THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF now() > r.token_expires_at THEN RETURN jsonb_build_object('status', 'expired'); END IF;

  RETURN jsonb_build_object(
    'status', 'ok',
    'approval_round_id', r.approval_round_id,
    'audience',    r.audience,
    'round_status', r.status,
    'total_amount', r.total_amount,
    'order', (SELECT jsonb_build_object(
                'quotation_id', q.quotation_id,
                'order_number', q.order_number,
                'plate_number', q.plate_number,
                'created_at',   q.created_at)
                FROM qvm_new_apps.quotations q WHERE q.quotation_id = r.quotation_id),
    'customer', (SELECT jsonb_build_object(
                   'end_customer_id', ec.end_customer_id,
                   'customer_kind',   ec.customer_kind,
                   'name', COALESCE(ec.name, ic.name))
                   FROM qvm_new_apps.end_customers ec
                   LEFT JOIN qvm_new_apps.insurance_companies ic ON ic.id = ec.insurance_company_id
                  WHERE ec.end_customer_id = r.end_customer_id),
    'expires_at', r.token_expires_at,
    -- How the offer was put to the customer: what the page shows, the message, the claim and the files.
    'offer', (SELECT jsonb_build_object(
                'show_part_number', o.show_part_number, 'show_alternatives', o.show_alternatives,
                'show_discount', o.show_discount, 'show_lead_time', o.show_lead_time,
                'show_notes', o.show_notes, 'show_photos', o.show_photos,
                'discount_mode', o.discount_mode, 'validity_days', o.validity_days,
                'claim_number', o.claim_number, 'message', o.message, 'subject', o.subject,
                'attachments', o.attachments, 'document_url', o.document_url, 'sent_at', o.sent_at,
                'total_before_discount', (SELECT COALESCE(SUM(COALESCE(ai.price_before_discount, ai.customer_price, 0) * COALESCE(ai.quantity, 1)), 0)
                                            FROM qvm_new_apps.quotation_approval_items ai
                                           WHERE ai.approval_round_id = r.approval_round_id AND ai.decision <> 'cancelled'))
                FROM qvm_new_apps.quotation_approval_offers o
               WHERE o.approval_round_id = r.approval_round_id AND r.audience = 'client'),
    'items', qvm_new_apps.approval_lines(r.quotation_id, r.audience, r.approval_round_id, r.status));
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.decide_approval_items(p_token uuid, p_decisions jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_round  bigint;
  v_status text;
BEGIN
  SELECT r.approval_round_id, r.status INTO v_round, v_status
    FROM qvm_new_apps.quotation_approval_rounds r
   WHERE r.access_token = p_token AND now() <= r.token_expires_at;

  IF v_round IS NULL THEN RETURN jsonb_build_object('status', 'not_found'); END IF;
  IF v_status <> 'pending' THEN
    RETURN jsonb_build_object('status', 'already_resolved', 'round_status', v_status);
  END IF;

  UPDATE qvm_new_apps.quotation_approval_items ai
     SET decision = COALESCE(NULLIF(x->>'decision', ''), ai.decision),
         reason   = NULLIF(btrim(COALESCE(x->>'reason', '')), ''),
         chosen_alternative_id =
           CASE WHEN x ? 'chosen_alternative_id'
                THEN NULLIF(x->>'chosen_alternative_id', '')::bigint
                ELSE ai.chosen_alternative_id END,
         decided_at = now()
    FROM jsonb_array_elements(COALESCE(p_decisions, '[]'::jsonb)) AS x
   WHERE ai.approval_round_id = v_round
     AND ai.approval_item_id = (x->>'approval_item_id')::bigint
     -- A chosen option has to be one of the options actually offered on this line, or the approver
     -- could be handed an id belonging to someone else's quote.
     AND (NOT (x ? 'chosen_alternative_id')
          OR NULLIF(x->>'chosen_alternative_id', '') IS NULL
          OR (EXISTS (SELECT 1 FROM qvm_new_apps.quotation_vendor_item_alternatives a
                      WHERE a.alternative_id = (x->>'chosen_alternative_id')::bigint
                        AND (a.cost_id = ai.cost_id
                             OR (a.source = 'qparts' AND a.quotation_item_id = ai.quotation_item_id)))
              -- A prepared offer names the alternatives the customer was shown; only those can be picked.
              AND (ai.shown_alternative_ids IS NULL
                   OR (x->>'chosen_alternative_id')::bigint = ANY(ai.shown_alternative_ids))));

  RETURN jsonb_build_object('status', 'success');
END;
$function$;

notify pgrst, 'reload schema';
