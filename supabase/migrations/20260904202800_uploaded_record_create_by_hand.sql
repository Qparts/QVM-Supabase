-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Adding one part without a spreadsheet.
--
-- Everything in these tables arrived through a file, which is fine for a price list and
-- absurd for the one part somebody just needs to add: building a one-row sheet, uploading it,
-- previewing it and publishing it to record a single number. This writes that one row.
--
-- batch_id stays null on purpose. It is what «came from a file» means here, so a row with no
-- batch is a row somebody typed, and the tables say where every number came from without a
-- new column to keep in step.
create or replace function qvm_new_apps.uploaded_record_create(p_kind text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_team boolean := qvm_new_apps.is_qparts_team();
  v_vendor integer := qvm_new_apps.current_upload_vendor_id();
  v_pn_raw text := nullif(btrim(coalesce(p_data->>'part_number','')), '');
  v_pn text;
  v_id bigint;
  v_vendor_id integer;
  v_branch integer;
  v_num numeric;
begin
  if not v_team and v_vendor is null then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;
  if v_pn_raw is null then
    return jsonb_build_object('status', false, 'message', 'رقم القطعة مطلوب', 'data', null);
  end if;

  -- The same normalisation an imported row goes through. A number typed here and the same
  -- number arriving in tomorrow's file have to land on one row, not two.
  v_pn := qvm_new_apps.normalize_part_number(v_pn_raw);
  if v_pn is null then
    return jsonb_build_object('status', false,
      'message', 'رقم القطعة لا يحتوي على حروف أو أرقام', 'data', null);
  end if;

  -- A vendor adds under their own name and cannot type somebody else's.
  v_vendor_id := case when v_team then nullif(p_data->>'vendor_id','')::integer else v_vendor end;
  v_branch := nullif(p_data->>'client_branch_id','')::integer;

  if p_kind = 'catalog' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    insert into qvm_new_apps.parts_catalog
      (clean_part_number, clean_make, clean_part_class, clean_country_manufacture,
       clean_name_ar, clean_name_en, source)
    values (v_pn,
            coalesce(nullif(btrim(coalesce(p_data->>'make','')), ''), 'UNKNOWN'),
            coalesce(nullif(btrim(coalesce(p_data->>'part_class','')), ''), 'commercial'),
            nullif(btrim(coalesce(p_data->>'country','')), ''),
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'name_en','')), ''),
            'manual')
    on conflict do nothing
    returning part_id into v_id;

  elsif p_kind = 'agency' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    v_num := nullif(btrim(coalesce(p_data->>'price','')), '')::numeric;
    if v_num is null then
      return jsonb_build_object('status', false, 'message', 'سعر الوكالة مطلوب', 'data', null);
    end if;
    insert into qvm_new_apps.agency_price_reference
      (source_part_number, clean_part_number, source_name, source_name_en, clean_name,
       brand, part_class, agency_price, dealer_agency_discount_pct,
       agency_price_after_discount, vendor_id, client_branch_id, source_label)
    values (v_pn_raw, v_pn,
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'name_en','')), ''),
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'make','')), ''),
            nullif(btrim(coalesce(p_data->>'part_class','')), ''),
            v_num,
            nullif(btrim(coalesce(p_data->>'discount_pct','')), '')::numeric,
            nullif(btrim(coalesce(p_data->>'price_after_discount','')), '')::numeric,
            v_vendor_id, v_branch, 'manual')
    on conflict do nothing
    returning id into v_id;

  elsif p_kind = 'stock' then
    v_num := nullif(btrim(coalesce(p_data->>'wholesale_price','')), '')::numeric;
    if v_num is null then
      return jsonb_build_object('status', false, 'message', 'سعر الجملة مطلوب', 'data', null);
    end if;
    insert into qvm_new_apps.inventory_stock
      (source_part_number, clean_part_number, source_name, clean_name, clean_name_en,
       brand, part_class, country_of_origin, quantity, is_available,
       wholesale_price, retail_price, vendor_id, client_branch_id)
    values (v_pn_raw, v_pn,
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'name','')), ''),
            nullif(btrim(coalesce(p_data->>'name_en','')), ''),
            nullif(btrim(coalesce(p_data->>'make','')), ''),
            nullif(btrim(coalesce(p_data->>'part_class','')), ''),
            nullif(btrim(coalesce(p_data->>'country','')), ''),
            nullif(btrim(coalesce(p_data->>'quantity','')), '')::integer,
            -- Same rule the edit path uses: availability follows the quantity, so a row
            -- entered as zero is not offered to a workshop that would never receive it.
            coalesce(nullif(btrim(coalesce(p_data->>'quantity','')), '')::integer, 0) > 0,
            v_num,
            nullif(btrim(coalesce(p_data->>'retail_price','')), '')::numeric,
            v_vendor_id, v_branch)
    on conflict do nothing
    returning id into v_id;

  elsif p_kind = 'purchases' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    insert into qvm_new_apps.part_purchase_history
      (source_part_number, clean_part_number, cost, cost_on, supplier_name,
       brand, brand_class, qty, retail_price, client_branch_id, origin)
    values (v_pn_raw, v_pn,
            nullif(btrim(coalesce(p_data->>'cost','')), '')::double precision,
            nullif(btrim(coalesce(p_data->>'cost_on','')), '')::date,
            nullif(btrim(coalesce(p_data->>'supplier','')), ''),
            nullif(btrim(coalesce(p_data->>'make','')), ''),
            nullif(btrim(coalesce(p_data->>'part_class','')), ''),
            nullif(btrim(coalesce(p_data->>'qty','')), '')::integer,
            nullif(btrim(coalesce(p_data->>'retail_price','')), '')::numeric,
            v_branch, 'manual')
    returning id into v_id;

  elsif p_kind = 'aliases' then
    if not v_team then
      return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
    end if;
    if qvm_new_apps.normalize_part_number(coalesce(p_data->>'alias','')) is null then
      return jsonb_build_object('status', false, 'message', 'الرقم المكافئ مطلوب', 'data', null);
    end if;
    insert into qvm_new_apps.part_aliases
      (clean_part_number, clean_alias, source_part_number, source_alias, brand, note)
    values (v_pn, qvm_new_apps.normalize_part_number(p_data->>'alias'),
            v_pn_raw, btrim(p_data->>'alias'),
            nullif(btrim(coalesce(p_data->>'make','')), ''),
            nullif(btrim(coalesce(p_data->>'note','')), ''))
    on conflict do nothing
    returning id into v_id;

  else
    return jsonb_build_object('status', false, 'message', 'unknown tab', 'data', null);
  end if;

  -- A row that is already there was not created, and saying «saved» would send somebody away
  -- believing a number is recorded that is not the one on screen.
  if v_id is null then
    return jsonb_build_object('status', false,
      'message', 'هذا الصنف موجود بالفعل في هذا الجدول — عدِّله من الصف نفسه', 'data', null);
  end if;

  insert into qvm_new_apps.upload_batch_log (action, detail, changed_by)
  values ('record_manual_create',
          jsonb_build_object('kind', p_kind, 'id', v_id, 'data', p_data), auth.uid());

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('id', v_id));
end
$function$;

revoke all on function qvm_new_apps.uploaded_record_create(text, jsonb) from public;
grant execute on function qvm_new_apps.uploaded_record_create(text, jsonb) to authenticated;
