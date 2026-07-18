-- Make cost/price logging functions table-agnostic and attach them to every table
-- that has a `cost` or `price_before_vat` column.

CREATE OR REPLACE FUNCTION qvm_new_apps.log_cost_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER AS $$
DECLARE
  v_cost_id INT;
  v_new_cost NUMERIC;
  v_old_cost NUMERIC;
BEGIN
  IF NOT (to_jsonb(NEW) ? 'cost') THEN
    RETURN NEW;
  END IF;

  v_new_cost := (to_jsonb(NEW)->>'cost')::NUMERIC;
  v_old_cost := (to_jsonb(OLD)->>'cost')::NUMERIC;

  IF v_new_cost IS DISTINCT FROM v_old_cost THEN
    v_cost_id := (to_jsonb(NEW)->>'cost_id')::INT;

    IF v_cost_id IS NOT NULL THEN
      INSERT INTO qvm_new_apps.cost_logs (cost_id, cost, created_by, created_at)
      VALUES (
        v_cost_id,
        v_new_cost,
        (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid,
        NOW()
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION qvm_new_apps.log_pricing_update()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER AS $$
DECLARE
  v_qid INT;
  v_new_price NUMERIC;
  v_old_price NUMERIC;
BEGIN
  IF NOT (to_jsonb(NEW) ? 'price_before_vat') THEN
    RETURN NEW;
  END IF;

  v_new_price := (to_jsonb(NEW)->>'price_before_vat')::NUMERIC;
  v_old_price := (to_jsonb(OLD)->>'price_before_vat')::NUMERIC;

  IF v_new_price IS DISTINCT FROM v_old_price THEN
    v_qid := (to_jsonb(NEW)->>'quotation_item_id')::INT;

    INSERT INTO qvm_new_apps.pricing_logs (quotation_item_id, price, created_by, created_at)
    VALUES (
      v_qid,
      v_new_price,
      (current_setting('request.jwt.claims', true)::jsonb->>'sub')::uuid,
      NOW()
    );
  END IF;

  RETURN NEW;
END;
$$;

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT table_name
    FROM information_schema.columns
    WHERE table_schema = 'qvm_new_apps'
      AND column_name = 'cost'
      AND table_name NOT IN ('cost_logs', 'cost_categories')
    GROUP BY table_name
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_%I_cost_log ON qvm_new_apps.%I; CREATE TRIGGER trg_%I_cost_log AFTER UPDATE ON qvm_new_apps.%I FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.log_cost_update();',
      r.table_name, r.table_name, r.table_name, r.table_name
    );
  END LOOP;

  FOR r IN
    SELECT table_name
    FROM information_schema.columns
    WHERE table_schema = 'qvm_new_apps'
      AND column_name = 'price_before_vat'
      AND table_name NOT IN ('pricing_logs', 'profit_margins')
    GROUP BY table_name
  LOOP
    EXECUTE format(
      'DROP TRIGGER IF EXISTS trg_%I_pricing_log ON qvm_new_apps.%I; CREATE TRIGGER trg_%I_pricing_log AFTER UPDATE ON qvm_new_apps.%I FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.log_pricing_update();',
      r.table_name, r.table_name, r.table_name, r.table_name
    );
  END LOOP;
END;
$$;
