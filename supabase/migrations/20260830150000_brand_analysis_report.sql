-- Management Overview → "Management Reports" tab: fifth report block — per-vehicle-brand table of
-- Requested / Confirmed / Returned quotation counts and a cycle-success rate.
--
-- "Brand" here is qvm_new_apps.quotation_items.main_brand (list_id = 4, "car_brand" — the vehicle
-- make, e.g. Toyota/Honda/Mercedes), NOT brand_class (list_id = 5, which is a part-condition class:
-- Genuine/OEM/Aftermarket/Used/Any — no manufacturer-brand list like Bosch/Denso/NGK exists in this
-- database). Confirmed by the user: all items on a single quotation always share the same
-- main_brand, so the brand is derived once per quotation the same way branch is derived elsewhere
-- in this tab (first item, ordered by quotation_item_id, wins) rather than fanning out per item.
--
-- Confirmed = the quotation has a confirmed_orders row (order-level test, same convention as
-- get_branch_order_status_report). Returned = at least one of the quotation's items reached
-- confirmed_items.item_status = 29 ("Return", list_id = 3).
CREATE OR REPLACE FUNCTION qvm_new_apps.get_brand_analysis_report(
  p_branch_id integer DEFAULT NULL,
  p_date_from timestamptz DEFAULT NULL,
  p_date_to timestamptz DEFAULT NULL
)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE
  v_branch_scope integer[];
  v_result jsonb;
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  v_branch_scope := qvm_new_apps.get_internal_branch_scope(auth.uid());

  WITH quotation_brand AS (
    SELECT
      q.quotation_id,
      (
        SELECT qi.main_brand
        FROM qvm_new_apps.quotation_items qi
        WHERE qi.quotation_id = q.quotation_id
        ORDER BY qi.quotation_item_id ASC
        LIMIT 1
      ) AS main_brand
    FROM qvm_new_apps.quotations q
    WHERE (p_date_from IS NULL OR q.created_at >= p_date_from)
      AND (p_date_to IS NULL OR q.created_at <= p_date_to)
      AND (p_branch_id IS NULL OR EXISTS (
        SELECT 1 FROM qvm_new_apps.quotation_items qi2
        WHERE qi2.quotation_id = q.quotation_id AND qi2.customer_id = p_branch_id
      ))
      AND (v_branch_scope IS NULL OR EXISTS (
        SELECT 1 FROM qvm_new_apps.quotation_items qi3
        WHERE qi3.quotation_id = q.quotation_id AND qi3.customer_id = ANY(v_branch_scope)
      ))
  ),
  classified AS (
    SELECT
      qb.quotation_id,
      qb.main_brand,
      EXISTS (
        SELECT 1 FROM qvm_new_apps.confirmed_orders co WHERE co.quotation_id = qb.quotation_id
      ) AS is_confirmed,
      EXISTS (
        SELECT 1
        FROM qvm_new_apps.confirmed_items ci
        JOIN qvm_new_apps.quotation_items qi4 ON qi4.quotation_item_id = ci.quotation_item_id
        WHERE qi4.quotation_id = qb.quotation_id AND ci.item_status = 29
      ) AS is_returned
    FROM quotation_brand qb
    WHERE qb.main_brand IS NOT NULL
  )
  SELECT jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE(jsonb_agg(to_jsonb(r) ORDER BY r.requested_count DESC), '[]'::jsonb)
  ) INTO v_result
  FROM (
    SELECT
      ld.list_data_id AS brand_id,
      ld.list_data AS brand_name,
      count(*) AS requested_count,
      count(*) FILTER (WHERE c.is_confirmed) AS confirmed_count,
      count(*) FILTER (WHERE c.is_returned) AS returned_count,
      round(
        count(*) FILTER (WHERE c.is_confirmed)::numeric / NULLIF(count(*), 0) * 100, 1
      ) AS success_rate
    FROM classified c
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = c.main_brand
    GROUP BY ld.list_data_id, ld.list_data
  ) r;

  RETURN v_result;
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.get_brand_analysis_report(integer, timestamptz, timestamptz) TO authenticated;
