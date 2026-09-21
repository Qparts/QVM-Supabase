-- The Extract PN desk adds, and removes, a part's photos from its table.
--
-- part_photo keeps the shape every reader already parses: a plain URL for one photo, a JSON array
-- for several, NULL for none. The list sent replaces the list held; the row's event log says so.
CREATE OR REPLACE FUNCTION qvm_new_apps.set_extract_photos(p_quotation_item_id integer, p_photos jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_uid uuid := auth.uid();
  v_qid integer;
  v_old text;
  v_urls text[];
  v_new text;
begin
  if v_uid is null then return jsonb_build_object('status', false, 'message', 'Not authenticated'); end if;
  if not qvm_new_apps.is_internal_user() then return jsonb_build_object('status', false, 'message', 'Internal users only'); end if;

  select qi.quotation_id, qi.part_photo into v_qid, v_old
    from qvm_new_apps.quotation_items qi where qi.quotation_item_id = p_quotation_item_id;
  if v_qid is null then return jsonb_build_object('status', false, 'message', 'Invalid quotation_item_id'); end if;

  select coalesce(array_agg(u order by ord), '{}') into v_urls
    from jsonb_array_elements_text(coalesce(p_photos, '[]'::jsonb)) with ordinality as e(u, ord)
   where btrim(u) <> '';

  v_new := case when coalesce(array_length(v_urls, 1), 0) = 0 then null
                when array_length(v_urls, 1) = 1 then v_urls[1]
                else to_jsonb(v_urls)::text end;

  update qvm_new_apps.quotation_items
     set part_photo = v_new, updated_at = now()
   where quotation_item_id = p_quotation_item_id
     and part_photo is distinct from v_new;

  perform qvm_new_apps._log_extract_event(p_quotation_item_id, 'photo_updated', v_old, v_new);
  perform qvm_new_apps._touch_extract_lock(v_qid);

  return jsonb_build_object('status', true, 'message', 'Saved',
                            'data', jsonb_build_object('part_photo', v_new, 'count', coalesce(array_length(v_urls, 1), 0)));
end;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.set_extract_photos(integer, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION qvm_new_apps.set_extract_photos(integer, jsonb) TO authenticated;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 36 $$;
