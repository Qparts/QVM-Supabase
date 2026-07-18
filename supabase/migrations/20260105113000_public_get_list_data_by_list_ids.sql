CREATE OR REPLACE FUNCTION public.get_list_data_by_list_ids(p_list_ids integer[])
RETURNS TABLE(list_id integer, list_data_id integer, label text)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public, qvm_new_apps
AS $$
  SELECT *
  FROM qvm_new_apps.get_list_data_by_list_ids(p_list_ids);
$$;

GRANT EXECUTE ON FUNCTION public.get_list_data_by_list_ids(integer[]) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_list_data_by_list_ids(integer[]) TO anon;
