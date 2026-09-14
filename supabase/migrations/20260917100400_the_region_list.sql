-- The thirteen regions, for the first field of the address form.
--
-- Region has always been derivable — a city knows its own — but the form asks for it first and
-- narrows the city list by it, which is how the national address is written and how everyone
-- expects to fill it in. Deriving it backwards from a city nobody has chosen yet is not possible.

CREATE OR REPLACE FUNCTION public.list_regions() RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO '' AS $$
  SELECT jsonb_build_object('success', true, 'data', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'region_id', r.region_id, 'name', r.name, 'region_code', r.region_code)
           ORDER BY r.sort_order, r.name)
      FROM qvm_new_apps.v_regions r WHERE r.is_active), '[]'::jsonb));
$$;

REVOKE ALL ON FUNCTION public.list_regions() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_regions() TO authenticated;
