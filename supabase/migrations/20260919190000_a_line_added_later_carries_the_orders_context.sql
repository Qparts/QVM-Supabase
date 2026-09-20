-- A line added later carries the order's context.
--
-- A line created with the order carries the branch, the VIN, the make, the model and the year. A
-- line added afterwards — by a vendor's suggestion, on the Extract PN page, from the RFQ dashboard,
-- by any path — arrived with none of them, so it was invisible to everything keyed on them: the
-- workshop's membership check, the auto-RFQ rules, the vehicle shown on the vendor's quote. The
-- table now fills them itself from a sibling line at insert, whatever inserted the row; lines already
-- added that way are brought in line once.
CREATE OR REPLACE FUNCTION qvm_new_apps.quotation_items_inherit_order_context()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE s record;
BEGIN
  IF NEW.quotation_id IS NULL THEN RETURN NEW; END IF;
  IF NEW.customer_id IS NOT NULL AND NEW.vin IS NOT NULL AND NEW.main_brand IS NOT NULL AND NEW.model IS NOT NULL AND NEW.year IS NOT NULL THEN
    RETURN NEW;
  END IF;
  -- The sibling that knows the most: a line with a VIN first, then the earliest line.
  SELECT qi.customer_id, qi.vin, qi.main_brand, qi.model, qi.year INTO s
    FROM qvm_new_apps.quotation_items qi
   WHERE qi.quotation_id = NEW.quotation_id
     AND (NEW.quotation_item_id IS NULL OR qi.quotation_item_id <> NEW.quotation_item_id)
   ORDER BY (qi.vin IS NOT NULL) DESC, (qi.main_brand IS NOT NULL) DESC, qi.quotation_item_id
   LIMIT 1;
  IF NOT FOUND THEN RETURN NEW; END IF;
  NEW.customer_id := COALESCE(NEW.customer_id, s.customer_id);
  NEW.vin         := COALESCE(NEW.vin,         s.vin);
  NEW.main_brand  := COALESCE(NEW.main_brand,  s.main_brand);
  NEW.model       := COALESCE(NEW.model,       s.model);
  NEW.year        := COALESCE(NEW.year,        s.year);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_quotation_items_inherit_order_context ON qvm_new_apps.quotation_items;
CREATE TRIGGER trg_quotation_items_inherit_order_context
BEFORE INSERT ON qvm_new_apps.quotation_items
FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.quotation_items_inherit_order_context();

-- Lines added before this, still missing what their siblings know. One representative line per
-- order (a line with a VIN first), joined back — the update target cannot be read inside a lateral.
UPDATE qvm_new_apps.quotation_items qi
   SET customer_id = COALESCE(qi.customer_id, s.customer_id),
       vin         = COALESCE(qi.vin,         s.vin),
       main_brand  = COALESCE(qi.main_brand,  s.main_brand),
       model       = COALESCE(qi.model,       s.model),
       year        = COALESCE(qi.year,        s.year)
  FROM (
    SELECT DISTINCT ON (o.quotation_id) o.quotation_id, o.customer_id, o.vin, o.main_brand, o.model, o.year
      FROM qvm_new_apps.quotation_items o
     WHERE o.customer_id IS NOT NULL OR o.vin IS NOT NULL OR o.main_brand IS NOT NULL
     ORDER BY o.quotation_id, (o.vin IS NOT NULL) DESC, (o.main_brand IS NOT NULL) DESC, o.quotation_item_id
  ) s
 WHERE s.quotation_id = qi.quotation_id
   AND (qi.customer_id IS NULL OR qi.vin IS NULL OR qi.main_brand IS NULL OR qi.model IS NULL OR qi.year IS NULL);

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 23 $$;
