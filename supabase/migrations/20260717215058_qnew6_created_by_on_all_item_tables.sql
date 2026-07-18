-- Synced from QVM/test branch applied migration history (version 20260717215058, name: qnew6_created_by_on_all_item_tables)

-- QNEW-6: created_by on every item table, auto-set from the authenticated user, immutable.

-- Auto-set created_by to auth.uid() at insert if the caller didn't set it explicitly.
CREATE OR REPLACE FUNCTION qvm_new_apps.set_created_by()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF NEW.created_by IS NULL THEN
    NEW.created_by := auth.uid();
  END IF;
  RETURN NEW;
END; $$;

-- created_by is an immutable audit field — never changes after creation.
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
;
