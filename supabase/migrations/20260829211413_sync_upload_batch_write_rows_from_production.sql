-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

create or replace function qvm_new_apps.upload_batch_write_rows(p_batch_id bigint)
returns integer language plpgsql security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_b record; v_written integer := 0; v_extra integer := 0; v_branches bigint[];
  v_p jsonb; v_gap integer;
  v_eff date; v_exp date; v_starts date; v_ends date; v_closes date; v_req_end date;
  v_country text; v_terms text; v_weeks integer; v_campaign bigint;
begin
  select * into v_b from qvm_new_apps.upload_batches where batch_id = p_batch_id;
  if v_b.batch_id is null then return 0; end if;
  v_p := coalesce(v_b.params, '{}'::jsonb);

  v_eff     := nullif(btrim(coalesce(v_p->>'effective_from','')), '')::date;
  v_exp     := nullif(btrim(coalesce(v_p->>'expires_on','')), '')::date;
  v_starts  := nullif(btrim(coalesce(v_p->>'starts_on','')), '')::date;
  v_ends    := nullif(btrim(coalesce(v_p->>'ends_on','')), '')::date;
  v_closes  := nullif(btrim(coalesce(v_p->>'closes_on','')), '')::date;
  v_req_end := nullif(btrim(coalesce(v_p->>'request_end_date','')), '')::date;
  v_country := nullif(btrim(coalesce(v_p->>'origin_country','')), '');
  v_terms   := nullif(btrim(coalesce(v_p->>'payment_terms','')), '');
  v_weeks   := nullif(btrim(coalesce(v_p->>'arrival_weeks','')), '')::integer;
  v_campaign := nullif(btrim(coalesce(v_p->>'campaign_id','')), '')::bigint;
  -- Offers, group imports and auctions each belong to something named. Without it the rows
  -- land as an unattached pile that nothing can close, price or show.
  if v_b.template_key in ('offers','group_import_request','stock_auction')
     and v_campaign is null then
    -- plpgsql's raise takes a bare %, not %s; the stray letter printed as «عرضًاs».
    raise exception 'اختر أو أنشئ % قبل الحفظ',
      case v_b.template_key when 'offers' then 'عرضًا'
                            when 'group_import_request' then 'شحنة'
                            else 'مزادًا' end;
  end if;

  v_branches := case
    when v_b.branch_scope = 'specific' and coalesce(array_length(v_b.branch_ids, 1), 0) > 0
    then v_b.branch_ids else array[null]::bigint[] end;

  if v_b.template_key = 'agency_price_list' then
    insert into qvm_new_apps.agency_price_reference
      (source_part_number, clean_part_number, source_name, clean_name, brand,
       agency_price, effective_from, expires_on, source_label, batch_id)
    select r.source_part_number, r.clean_part_number, r.source_name, r.clean_name, r.brand,
           (r.raw->>'agency_price')::numeric,
           coalesce(nullif(r.raw->>'effective_from','')::date, v_eff),
           coalesce(nullif(r.raw->>'expires_on','')::date, v_exp),
           coalesce(v_b.source_label, 'agency'), v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
    on conflict (clean_part_number, lower(source_label)) do update set
      source_part_number = excluded.source_part_number,
      source_name = excluded.source_name, clean_name = excluded.clean_name,
      brand = excluded.brand, agency_price = excluded.agency_price,
      effective_from = excluded.effective_from, expires_on = excluded.expires_on,
      batch_id = excluded.batch_id, updated_at = now();
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'stock_on_hand' then
    insert into qvm_new_apps.inventory_stock
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       source_name, clean_name, source_name_en, clean_name_en, name_is_guess, brand, part_class, country_of_origin,
       quantity, is_available, wholesale_price, retail_price, before_discount_price,
       claimed_agency_price, claimed_agency_price_after_discount,
       dealer_agency_discount_pct, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           r.source_name_en, r.clean_name_en, r.name_is_guess,
           r.brand, r.part_class, r.country_of_origin,
           case when r.raw->>'qty' ~ '^[0-9]+$' then (r.raw->>'qty')::integer else null end,
           coalesce(lower(btrim(r.raw->>'qty')) not in ('0','notavailable','not available','غير متوفر'), true),
           nullif(r.raw->>'wholesale_price','')::numeric,
           nullif(r.raw->>'retail_price','')::numeric,
           nullif(r.raw->>'before_discount_price','')::numeric,
           nullif(r.raw->>'agency_price','')::numeric,
           nullif(r.raw->>'agency_price_after_discount','')::numeric,
           nullif(r.raw->>'dealer_agency_discount_pct','')::numeric,
           v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready'
    on conflict (coalesce(vendor_id, -1), coalesce(vendor_branch_id, -1), clean_part_number)
    do update set
      source_part_number = excluded.source_part_number,
      source_name = excluded.source_name, clean_name = excluded.clean_name,
      source_name_en = excluded.source_name_en, clean_name_en = excluded.clean_name_en,
      name_is_guess = excluded.name_is_guess,
      brand = excluded.brand, part_class = excluded.part_class,
      country_of_origin = excluded.country_of_origin,
      quantity = excluded.quantity, is_available = excluded.is_available,
      wholesale_price = excluded.wholesale_price, retail_price = excluded.retail_price,
      before_discount_price = excluded.before_discount_price,
      claimed_agency_price = excluded.claimed_agency_price,
      claimed_agency_price_after_discount = excluded.claimed_agency_price_after_discount,
      dealer_agency_discount_pct = excluded.dealer_agency_discount_pct,
      batch_id = excluded.batch_id, updated_at = now();
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'past_purchases' then
    insert into qvm_new_apps.part_purchase_history
      (source_part_number, clean_part_number, cost, cost_on, source_cost_date,
       supplier_name, city, qty, brand, brand_class, origin, batch_id)
    select r.source_part_number, r.clean_part_number,
           (r.raw->>'unit_price')::double precision,
           nullif(r.raw->>'purchase_date','')::date, r.raw->>'purchase_date',
           r.raw->>'supplier_name', nullif(btrim(coalesce(r.raw->>'city','')),''),
           nullif(r.raw->>'qty','')::integer,
           r.brand, r.part_class, 'external_excel', v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and not exists (
         select 1 from qvm_new_apps.part_purchase_history h
          where h.clean_part_number = r.clean_part_number
            and coalesce(h.supplier_name,'') = coalesce(r.raw->>'supplier_name','')
            and h.cost_on is not distinct from nullif(r.raw->>'purchase_date','')::date
            and h.cost is not distinct from (r.raw->>'unit_price')::double precision);
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'aliases' then
    insert into qvm_new_apps.part_aliases
      (clean_part_number, clean_alias, source_part_number, source_alias, brand, note, batch_id)
    select r.clean_part_number, qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number'),
           r.source_part_number, r.raw->>'alias_part_number', r.brand, r.raw->>'note', v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') is not null
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') <> r.clean_part_number
    on conflict (clean_part_number, clean_alias) do nothing;
    get diagnostics v_written = row_count;

    insert into qvm_new_apps.part_aliases
      (clean_part_number, clean_alias, source_part_number, source_alias, brand, note, batch_id)
    select qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number'), r.clean_part_number,
           r.raw->>'alias_part_number', r.source_part_number, r.brand, r.raw->>'note', v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') is not null
       and qvm_new_apps.normalize_part_number(r.raw->>'alias_part_number') <> r.clean_part_number
    on conflict (clean_part_number, clean_alias) do nothing;
    get diagnostics v_extra = row_count;
    v_written := v_written + v_extra;

  elsif v_b.template_key = 'offers' then
    select count(*) into v_gap
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready'
       and (coalesce(nullif(r.raw->>'starts_on','')::date, v_starts) is null
         or coalesce(nullif(r.raw->>'ends_on','')::date, v_ends) is null);
    if v_gap > 0 then
      raise exception 'حدّد بداية العرض ونهايته في شاشة الرفع — % صف بلا نافذة سريان', v_gap;
    end if;

    insert into qvm_new_apps.part_offers
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       offer_price, part_class, starts_on, ends_on, qty_limit, campaign_id, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number,
           (r.raw->>'offer_price')::numeric, r.part_class,
           coalesce(nullif(r.raw->>'starts_on','')::date, v_starts),
           coalesce(nullif(r.raw->>'ends_on','')::date, v_ends),
           nullif(r.raw->>'qty_limit','')::integer, v_campaign, v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'group_import_request' then
    insert into qvm_new_apps.group_import_requests
      (source_part_number, clean_part_number, source_name, clean_name, qty,
       target_price, brand, part_class, origin_country, payment_terms, arrival_weeks, request_end_date, campaign_id, batch_id)
    select r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           (r.raw->>'qty')::integer, nullif(r.raw->>'target_price','')::numeric,
           r.brand, r.part_class,
           coalesce(nullif(btrim(coalesce(r.raw->>'origin_country','')),''), v_country),
           coalesce(nullif(btrim(coalesce(r.raw->>'payment_terms','')),''), v_terms),
           coalesce(nullif(r.raw->>'arrival_weeks','')::integer, v_weeks),
           coalesce(nullif(r.raw->>'request_end_date','')::date, v_req_end),
           v_campaign, v_b.batch_id
      from qvm_new_apps.upload_rows r
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  elsif v_b.template_key = 'stock_auction' then
    insert into qvm_new_apps.stock_auction_items
      (vendor_id, vendor_branch_id, source_part_number, clean_part_number,
       source_name, clean_name, source_name_en, clean_name_en,
       qty, brand, part_class, reserve_price, closes_on, campaign_id, batch_id)
    select v_b.source_id::integer, br.id,
           r.source_part_number, r.clean_part_number, r.source_name, r.clean_name,
           r.source_name_en, r.clean_name_en,
           (r.raw->>'qty')::integer, r.brand, r.part_class,
           nullif(r.raw->>'reserve_price','')::numeric,
           coalesce(nullif(r.raw->>'closes_on','')::date, v_closes), v_campaign, v_b.batch_id
      from qvm_new_apps.upload_rows r
      cross join unnest(v_branches) as br(id)
     where r.batch_id = p_batch_id and r.state = 'ready';
    get diagnostics v_written = row_count;

  else
    raise exception 'نوع ملف غير مدعوم للنشر: %', v_b.template_key;
  end if;

  return v_written;
end
$function$;
