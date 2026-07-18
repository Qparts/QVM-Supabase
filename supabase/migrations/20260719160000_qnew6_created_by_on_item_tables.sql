-- QNEW-6: created_by on every item table, auto-set from the authenticated user, immutable.
-- (quotation_items already had created_by from QNEW-5; this adds it to the rest + the triggers.)
-- Applied to production via MCP; this file is the repo copy.

CREATE OR REPLACE FUNCTION qvm_new_apps.set_created_by()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.created_by IS NULL THEN
    NEW.created_by := auth.uid();
  END IF;
  RETURN NEW;
END; $$;

CREATE OR REPLACE FUNCTION qvm_new_apps.freeze_created_by()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  NEW.created_by := OLD.created_by;
  RETURN NEW;
END; $$;

DO $do$
DECLARE
  t text;
  tables text[] := ARRAY[
    'quotation_items','confirmed_items','creditnote_items','delivery_items','invoice_items',
    'pickup_items','purchase_items','quotation_vendor_items','return_items','vendor_creditnote_items'
  ];
BEGIN
  FOREACH t IN ARRAY tables LOOP
    EXECUTE format('ALTER TABLE qvm_new_apps.%I ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL', t);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_set_created_by ON qvm_new_apps.%I', t);
    EXECUTE format('CREATE TRIGGER trg_set_created_by BEFORE INSERT ON qvm_new_apps.%I FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.set_created_by()', t);
    EXECUTE format('DROP TRIGGER IF EXISTS trg_freeze_created_by ON qvm_new_apps.%I', t);
    EXECUTE format('CREATE TRIGGER trg_freeze_created_by BEFORE UPDATE ON qvm_new_apps.%I FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.freeze_created_by()', t);
  END LOOP;
END $do$;

-- Resolve who created a quotation item (admin item detail / history view).
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
