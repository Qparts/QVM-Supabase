-- One list of grades, in one order.
--
-- get_vendor_quotation_extras_by_token carried its own copy of the brand_class query, written
-- before list_brand_classes existed. Now that the grade order means something -- Aftermarket
-- followed by its two grades, not scattered by insertion id -- two copies means the magic-link page
-- offers the grades in a different order from the dashboard. It calls the list function instead.

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_extras_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
declare
  v_quotation_id integer;
  v_quotation_vendor_id bigint;
  v_vendor_id bigint;
  v_expires_at timestamptz;
begin
  select qv.quotation_id, qv.quotation_vendor_id, qv.vendor_id, qv.token_expires_at
    into v_quotation_id, v_quotation_vendor_id, v_vendor_id, v_expires_at
    from qvm_new_apps.quotation_vendors qv
   where qv.access_token = p_token;

  -- Same two answers the detail loader gives, so the page can treat them alike.
  if v_quotation_id is null then
    return jsonb_build_object('status', 'not_found');
  end if;
  if now() > v_expires_at then
    return jsonb_build_object('status', 'expired');
  end if;

  return jsonb_build_object(
    'status', 'ok',

    -- Only this vendor's own rows on this quotation. Another vendor's part
    -- numbers on the same quotation are not theirs to see.
    'vendor_part_numbers', coalesce((
      select jsonb_object_agg(x.cost_id::text, x.vendor_part_number)
        from qvm_new_apps.quotation_vendor_items x
       where x.quotation_vendor_id = v_quotation_vendor_id
         and x.vendor_part_number is not null
         and btrim(x.vendor_part_number) <> ''), '{}'::jsonb),

    -- Keyed by item id, for the lines of this quotation only.
    'item_years', coalesce((
      select jsonb_object_agg(i.quotation_item_id::text, i.year)
        from qvm_new_apps.quotation_items i
       where i.quotation_id = v_quotation_id
         and i.year is not null and btrim(i.year::text) <> ''), '{}'::jsonb),

    -- A reference list, not anyone's data — the same rows get_brand_classes
    -- returns, minus the login it insists on.
    'brand_classes', qvm_new_apps.list_brand_classes(),

    -- The other two halves of the grade/brand/origin column. Reference lists like brand_classes
    -- above -- the magic link has no session, so it cannot call the logged-in list RPCs.
    'brands', qvm_new_apps.list_part_brands(),
    'origin_countries', qvm_new_apps.list_origin_countries(),

    -- This vendor's own files on this quotation, whoever uploaded them. Scoped by vendor_id, so
    -- another vendor's quote on the same order is never returned, and neither are the team's
    -- internal order-level files (which carry no vendor_id).
    'attachments', coalesce((
      select jsonb_agg(jsonb_build_object(
               'attachment_id', a.attachment_id,
               'quotation_id',  a.quotation_id,
               'vendor_id',     a.vendor_id,
               'quotation_vendor_id', a.quotation_vendor_id,
               'file_url',      a.file_url,
               'file_path',     a.file_path,
               'file_name',     a.file_name,
               'file_type',     a.file_type,
               'mime_type',     a.mime_type,
               'file_size',     a.file_size,
               'ai_extracted',  a.ai_extracted,
               'created_at',    a.created_at,
               'created_by',    a.created_by) order by a.created_at desc)
        from qvm_new_apps.quotation_attachments a
       where a.quotation_id = v_quotation_id
         and a.vendor_id is not null
         and a.vendor_id = v_vendor_id), '[]'::jsonb)
  );
end
$function$;
