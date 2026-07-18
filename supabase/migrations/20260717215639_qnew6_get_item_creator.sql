-- Synced from QVM/test branch applied migration history (version 20260717215639, name: qnew6_get_item_creator)

-- Resolve who created a quotation item (for the admin item detail / history view). Read-only.
CREATE OR REPLACE FUNCTION public.get_item_creator(p_quotation_item_id bigint)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'user_id',  qi.created_by,
    'user_name', COALESCE(ud.user_name, ''),
    'role',      COALESCE(rl.list_data, ''),
    'company',   COALESCE(ud.email, '')
  )
  FROM qvm_new_apps.quotation_items qi
  LEFT JOIN qvm_new_apps.user_data ud ON ud.user_id = qi.created_by
  LEFT JOIN qvm_new_apps.list_data rl ON rl.list_data_id = ud.user_role
  WHERE qi.quotation_item_id = p_quotation_item_id;
$$;
REVOKE ALL ON FUNCTION public.get_item_creator(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_item_creator(bigint) TO authenticated;
;
