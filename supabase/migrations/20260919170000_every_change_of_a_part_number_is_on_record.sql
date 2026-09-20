-- Every change of a part number is on record, and the vendor sees it.
--
-- A part number changes in several places — the pricing page, accepting a vendor's proposal, an
-- edit on the order. Each change is written by a trigger on the column itself, with who made it
-- and in which role, so nothing is missed whatever the path. The vendor's quotation carries the
-- changes made after they were first sent the line, and their screen says "changed from #old".
CREATE TABLE IF NOT EXISTS qvm_new_apps.quotation_item_part_number_changes (
  change_id         bigserial PRIMARY KEY,
  quotation_item_id bigint NOT NULL,
  old_part_number   text,
  new_part_number   text,
  changed_by        uuid,
  changed_by_name   text,
  changed_by_role   text NOT NULL CHECK (changed_by_role IN ('internal', 'vendor', 'workshop', 'customer', 'system')),
  changed_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_part_number_changes_item ON qvm_new_apps.quotation_item_part_number_changes (quotation_item_id, changed_at);
GRANT SELECT ON qvm_new_apps.quotation_item_part_number_changes TO authenticated, service_role;
GRANT INSERT ON qvm_new_apps.quotation_item_part_number_changes TO service_role;

CREATE OR REPLACE FUNCTION qvm_new_apps.log_part_number_change()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
DECLARE
  v_role text := 'system';
  v_name text;
  v_type integer;
  v_rolei integer;
BEGIN
  IF OLD.part_number IS NOT DISTINCT FROM NEW.part_number THEN RETURN NEW; END IF;
  IF auth.uid() IS NOT NULL THEN
    SELECT ud.user_type, ud.user_role, ud.user_name INTO v_type, v_rolei, v_name
      FROM qvm_new_apps.user_data ud WHERE ud.user_id = auth.uid();
    v_role := CASE WHEN v_type = 185 THEN 'internal'
                   WHEN v_type = 205 THEN 'vendor'
                   WHEN v_type = 183 THEN CASE WHEN v_rolei IN (qvm_new_apps.customer_role_id(false), qvm_new_apps.customer_role_id(true))
                                               THEN 'customer' ELSE 'workshop' END
                   ELSE 'system' END;
  END IF;
  INSERT INTO qvm_new_apps.quotation_item_part_number_changes
    (quotation_item_id, old_part_number, new_part_number, changed_by, changed_by_name, changed_by_role)
  VALUES (NEW.quotation_item_id, OLD.part_number, NEW.part_number, auth.uid(), v_name, v_role);
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- The record must never block the change itself.
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_log_part_number_change ON qvm_new_apps.quotation_items;
CREATE TRIGGER trg_log_part_number_change
AFTER UPDATE OF part_number ON qvm_new_apps.quotation_items
FOR EACH ROW EXECUTE FUNCTION qvm_new_apps.log_part_number_change();

-- The history of one line, for the Qparts team and for a vendor who has a line on it.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_part_number_changes(p_quotation_item_id bigint)
 RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$
BEGIN
  IF NOT (qvm_new_apps.is_qparts_team()
          OR EXISTS (SELECT 1 FROM qvm_new_apps.quotation_vendor_items qvi
                       JOIN qvm_new_apps.user_data ud ON ud.user_vendor = qvi.vendor_id
                      WHERE qvi.quotation_item_id = p_quotation_item_id AND ud.user_id = auth.uid())) THEN
    RAISE EXCEPTION 'Not allowed to read this line''s history';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
             'change_id', c.change_id, 'old_part_number', c.old_part_number, 'new_part_number', c.new_part_number,
             'changed_by_name', c.changed_by_name, 'changed_by_role', c.changed_by_role, 'changed_at', c.changed_at)
             ORDER BY c.changed_at)
      FROM qvm_new_apps.quotation_item_part_number_changes c WHERE c.quotation_item_id = p_quotation_item_id), '[]'::jsonb);
END $$;
CREATE OR REPLACE FUNCTION public.list_part_number_changes(p_quotation_item_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public' AS $$ SELECT qvm_new_apps.list_part_number_changes(p_quotation_item_id) $$;
REVOKE ALL ON FUNCTION public.list_part_number_changes(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_part_number_changes(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_part_number_changes(bigint) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_details(p_quotation_id integer, p_vendor_id integer, p_vendor_branch_ids bigint[] DEFAULT NULL::bigint[], p_quotation_vendor_id bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_result JSON;
    v_quotation_vendor_ids BIGINT[];
    v_vendor_status INT;
BEGIN
    IF p_quotation_vendor_id IS NOT NULL THEN
      -- Precise, unambiguous scope: exactly the row the caller clicked into. Still verify it
      -- actually belongs to this vendor/quotation so a stale/foreign id can't leak data.
      SELECT array_agg(qv.quotation_vendor_id), MIN(qv.vendor_status)
      INTO v_quotation_vendor_ids, v_vendor_status
      FROM qvm_new_apps.quotation_vendors qv
      WHERE qv.quotation_id = p_quotation_id
        AND qv.vendor_id = p_vendor_id
        AND qv.quotation_vendor_id = p_quotation_vendor_id;
    ELSE
      SELECT array_agg(qv.quotation_vendor_id), MIN(qv.vendor_status)
      INTO v_quotation_vendor_ids, v_vendor_status
      FROM qvm_new_apps.quotation_vendors qv
      WHERE qv.quotation_id = p_quotation_id
        AND qv.vendor_id = p_vendor_id
        AND (p_vendor_branch_ids IS NULL OR qv.vendor_branch_id = ANY(p_vendor_branch_ids));
    END IF;

    SELECT json_build_object(
        'status', 'success',
        'message', 'Quotation details fetched successfully',
        'data', jsonb_build_object(
            'quotation_vendor_id', v_quotation_vendor_ids[1],
            'vendor_status', v_vendor_status,
            'vendor_name', (SELECT v.vendor_name FROM qvm_new_apps.vendors v WHERE v.vendor_id = p_vendor_id),
            'quotation', (
                SELECT jsonb_build_object(
                    'quotation_id', q.quotation_id,
                    'order_number', q.order_number,
                    'plate_number', q.plate_number,
                    'delivery_type', q.delivery_type,
                    'account_manager', q.account_manager,
                    'created_at', q.created_at,
                    'updated_at', q.updated_at
                )
                FROM qvm_new_apps.quotations q
                WHERE q.quotation_id = p_quotation_id
            ),
            'items', (
                SELECT json_agg(t.obj)
                FROM (
                    SELECT DISTINCT ON (qi.quotation_item_id)
                        json_build_object(
                            'quotation_item_id', qi.quotation_item_id,
                            'vin', qi.vin,
                            'main_brand', qi.main_brand,
                            'main_brand_name', main_brand_ld.list_data,
                            'model', qi.model,
                            'part_description', qi.part_description,
                            'part_number', qi.part_number,
                -- The line's part-number changes since this vendor was first sent it, oldest first.
                'part_number_changes', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
                        'old_part_number', c.old_part_number, 'new_part_number', c.new_part_number,
                        'changed_at', c.changed_at, 'changed_by_role', c.changed_by_role) ORDER BY c.changed_at), '[]'::jsonb)
                    FROM qvm_new_apps.quotation_item_part_number_changes c
                   WHERE c.quotation_item_id = qi.quotation_item_id
                     AND c.changed_at > COALESCE((SELECT min(x.created_at) FROM qvm_new_apps.quotation_vendor_items x
                                                   WHERE x.quotation_item_id = qi.quotation_item_id AND x.vendor_id = p_vendor_id), '-infinity'::timestamptz)),
                            -- The line's part-number changes since this vendor was first sent it, oldest first.
                            'part_number_changes', (SELECT COALESCE(json_agg(json_build_object(
                                    'old_part_number', c.old_part_number, 'new_part_number', c.new_part_number,
                                    'changed_at', c.changed_at, 'changed_by_role', c.changed_by_role) ORDER BY c.changed_at), '[]'::json)
                                FROM qvm_new_apps.quotation_item_part_number_changes c
                               WHERE c.quotation_item_id = qi.quotation_item_id
                                 AND c.changed_at > COALESCE((SELECT min(x.created_at) FROM qvm_new_apps.quotation_vendor_items x
                                                               WHERE x.quotation_item_id = qi.quotation_item_id AND x.vendor_id = p_vendor_id), '-infinity'::timestamptz)),
                            'quantity', qi.quantity,
                            'brand_class', qi.brand_class,
                            'brand_class_name', brand_class_ld.list_data,
                            'part_category', qi.part_category,
                            'part_category_name', part_category_ld.list_data,
                            'part_photo', qi.part_photo,
                            'item_status', qi.item_status,
                            'item_status_name', item_status_ld.list_data,
                            'alternative_part_number', qi.alternative_part_number,
                            'created_at', qi.created_at,
                            'updated_at', qi.updated_at,
                            'vendor_pricing', (
                                SELECT COALESCE(
                                    json_agg(
                                        json_build_object(
                                            'cost_id', qvi2.cost_id,
                                            'cost', qvi2.cost,
                                            'vendor_id', qvi2.vendor_id,
                                            'vendor_item_status', qvi2.vendor_item_status,
                                            'discount_percent', qvi2.discount_percent,
                                            'agency_price', qvi2.agency_price,
                                            'sla', qvi2.sla,
                                            'best_cost', qvi2.best_cost,
                                            'available_quantity', qvi2.available_quantity,
                                            'quotation_vendor_id', qvi2.quotation_vendor_id,
                                            'available_brand_class', qvi2.available_brand_class,
                                            'alternative_part_number', qvi2.alternative_part_number,
                                            'created_at', qvi2.created_at,
                                            'updated_at', qvi2.updated_at,
                                            'available_brand_id', qvi2.available_brand_id,
                                            'available_brand_name', avail_brand_ld.list_data,
                                            'origin_country_id', qvi2.origin_country_id,
                                            'origin_country_name_en', avail_origin.name_en,
                                            'origin_country_name_ar', avail_origin.name_ar,
                                            'note', qvi2.note,
                                            'files', COALESCE(qvi2.files, '[]'::jsonb),
                                            'improvement_requested_at', qvi2.improvement_requested_at,
                                            'improvement_note', qvi2.improvement_note,
                                            'previous_cost', qvi2.previous_cost,
                                            -- The vendor's alternatives for this line, loaded with
                                            -- the line itself so the البدائل badge has its count on
                                            -- first paint instead of after a second round trip.
                                            'alternatives', qvm_new_apps.alternatives_of_cost(qvi2.cost_id),
                                            'item_notes', (
                                                SELECT json_agg(
                                                    json_build_object(
                                                        'note_description', n.note_description,
                                                        'note_attachment', n.note_attachment,
                                                        'created_at', n.created_at,
                                                        'user_name', u.user_name
                                                    )
                                                    ORDER BY n.created_at DESC
                                                )
                                                FROM qvm_new_apps.notes n
                                                LEFT JOIN qvm_new_apps.user_data u
                                                  ON u.user_id = n.user_id
                                                WHERE n.note_type = 'quotation_vendor_item'
                                                  AND n.type_id = qvi2.cost_id
                                                  AND n.is_internal = FALSE
                                            )
                                        )
                                    ),
                                    '[]'::json
                                )
                                FROM qvm_new_apps.quotation_vendor_items qvi2
                                LEFT JOIN qvm_new_apps.list_data avail_brand_ld
                                       ON avail_brand_ld.list_data_id = qvi2.available_brand_id
                                LEFT JOIN qvm_new_apps.origin_countries avail_origin
                                       ON avail_origin.origin_country_id = qvi2.origin_country_id
                                WHERE qvi2.quotation_item_id = qi.quotation_item_id
                                  AND qvi2.vendor_id = p_vendor_id
                                  AND qvi2.quotation_vendor_id = ANY(v_quotation_vendor_ids)
                            )
                        ) AS obj
                    FROM qvm_new_apps.quotation_vendor_items qvi
                    JOIN qvm_new_apps.quotation_items qi
                      ON qi.quotation_item_id = qvi.quotation_item_id
                    LEFT JOIN qvm_new_apps.list_data main_brand_ld
                           ON qi.main_brand = main_brand_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data brand_class_ld
                           ON qi.brand_class = brand_class_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data part_category_ld
                           ON qi.part_category = part_category_ld.list_data_id
                    LEFT JOIN qvm_new_apps.list_data item_status_ld
                           ON qi.item_status = item_status_ld.list_data_id
                    WHERE qvi.vendor_id = p_vendor_id
                      AND qvi.quotation_vendor_id = ANY(v_quotation_vendor_ids)
                    ORDER BY qi.quotation_item_id
                ) t
            )
        )
    )
    INTO v_result;

    RETURN v_result;
END;
$function$;

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 21 $$;
