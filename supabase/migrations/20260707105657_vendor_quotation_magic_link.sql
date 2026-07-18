-- Synced from QVM/test branch applied migration history (version 20260707105657, name: vendor_quotation_magic_link)
ALTER TABLE qvm_new_apps.quotation_vendors
  ADD COLUMN access_token uuid NOT NULL DEFAULT gen_random_uuid(),
  ADD COLUMN token_expires_at timestamptz NOT NULL DEFAULT (now() + interval '7 days');

ALTER TABLE qvm_new_apps.quotation_vendors
  ADD CONSTRAINT quotation_vendors_access_token_key UNIQUE (access_token);

CREATE OR REPLACE FUNCTION qvm_new_apps.create_vendors_quotations(p_vendor_selections jsonb, p_quotation_id bigint, p_quotation_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
  v_selection           JSONB;
  v_vendor_id           BIGINT;
  v_vendor_branch_id    BIGINT;
  v_quotation_vendor_id BIGINT;
  v_access_token        UUID;
  v_results             JSONB := '[]'::jsonb;
  rec                   JSONB;
  v_item_id             BIGINT;
  v_cost                NUMERIC;
  v_from_database       BOOLEAN;
  v_discount            NUMERIC;
  v_vendor_item_status  INTEGER;
  v_new_cost_id         BIGINT;
BEGIN
  IF p_vendor_selections IS NULL OR jsonb_typeof(p_vendor_selections) <> 'array' OR jsonb_array_length(p_vendor_selections) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_vendor_selections must be a non-empty JSON array');
  END IF;

  IF p_quotation_items IS NULL OR jsonb_typeof(p_quotation_items) <> 'array' OR jsonb_array_length(p_quotation_items) = 0 THEN
    RETURN jsonb_build_object('status', false, 'message', 'p_quotation_items must be a non-empty JSON array');
  END IF;

  FOR v_selection IN SELECT * FROM jsonb_array_elements(p_vendor_selections) LOOP
    v_vendor_id        := (v_selection->>'vendor_id')::BIGINT;
    v_vendor_branch_id := NULLIF(v_selection->>'vendor_branch_id', '')::BIGINT;

    SELECT quotation_vendor_id, access_token
    INTO v_quotation_vendor_id, v_access_token
    FROM qvm_new_apps.quotation_vendors
    WHERE vendor_id = v_vendor_id
      AND quotation_id = p_quotation_id
      AND vendor_branch_id IS NOT DISTINCT FROM v_vendor_branch_id
    LIMIT 1;

    IF v_quotation_vendor_id IS NULL THEN
      INSERT INTO qvm_new_apps.quotation_vendors (vendor_id, vendor_branch_id, quotation_id, created_at)
      VALUES (v_vendor_id, v_vendor_branch_id, p_quotation_id, NOW())
      RETURNING quotation_vendor_id, access_token INTO v_quotation_vendor_id, v_access_token;
    ELSE
      -- Resend: keep the same link working, just push its expiry out another 7 days.
      UPDATE qvm_new_apps.quotation_vendors
      SET token_expires_at = now() + interval '7 days'
      WHERE quotation_vendor_id = v_quotation_vendor_id;
    END IF;

    -- Replace: delete old items for this vendor so only newly selected items remain
    DELETE FROM qvm_new_apps.quotation_vendor_items
    WHERE vendor_id = v_vendor_id
      AND quotation_vendor_id = v_quotation_vendor_id;

    FOR rec IN SELECT * FROM jsonb_array_elements(p_quotation_items) LOOP
      v_item_id            := (rec->>'quotation_item_id')::BIGINT;
      v_cost               := NULLIF(rec->>'cost','')::NUMERIC;
      v_discount           := NULLIF(rec->>'discount_percent','')::NUMERIC;
      v_from_database      := (rec->>'from_database')::BOOLEAN;
      v_vendor_item_status := (rec->>'vendor_item_status')::INTEGER;

      INSERT INTO qvm_new_apps.quotation_vendor_items (
        quotation_item_id, vendor_id, quotation_vendor_id,
        best_cost, cost, discount_percent, from_database,
        vendor_item_status, created_at, updated_at
      )
      VALUES (
        v_item_id, v_vendor_id, v_quotation_vendor_id,
        FALSE, v_cost, v_discount, v_from_database,
        v_vendor_item_status, NOW(), NOW()
      )
      ON CONFLICT (quotation_item_id, vendor_id) DO UPDATE
      SET cost = EXCLUDED.cost,
          discount_percent = EXCLUDED.discount_percent,
          from_database = EXCLUDED.from_database,
          vendor_item_status = EXCLUDED.vendor_item_status,
          updated_at = NOW()
      RETURNING cost_id INTO v_new_cost_id;

      v_results := v_results || jsonb_build_array(
        jsonb_build_object(
          'quotation_vendor_id', v_quotation_vendor_id,
          'vendor_id', v_vendor_id,
          'vendor_branch_id', v_vendor_branch_id,
          'access_token', v_access_token,
          'quotation_id', p_quotation_id,
          'quotation_item_id', v_item_id,
          'cost_id', v_new_cost_id,
          'inserted', v_new_cost_id IS NOT NULL
        )
      );

    END LOOP;

  END LOOP;

  -- Update selected quotation items status to "Sent To Vendor"
  WITH sent_items AS (
    SELECT DISTINCT (sent_rec->>'quotation_item_id')::bigint AS quotation_item_id
    FROM jsonb_array_elements(p_quotation_items) sent_rec
  )
  UPDATE qvm_new_apps.quotation_items qi
  SET item_status = 237,
      updated_at = now()
  FROM sent_items si
  WHERE qi.quotation_item_id = si.quotation_item_id;

  INSERT INTO qvm_new_apps.status_logs (quotation_item_id, item_status, status_changed_by, created_at)
  SELECT DISTINCT (log_rec->>'quotation_item_id')::bigint, 237, auth.uid(), now()
  FROM jsonb_array_elements(p_quotation_items) log_rec
  WHERE auth.uid() IS NOT NULL
  ON CONFLICT DO NOTHING;

  RETURN jsonb_build_object('status', true, 'message', 'Vendor quotations and items processed', 'data', v_results);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_quotation_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_quotation_id integer;
  v_vendor_id integer;
  v_expires_at timestamptz;
BEGIN
  SELECT qv.quotation_id, qv.vendor_id, qv.token_expires_at
  INTO v_quotation_id, v_vendor_id, v_expires_at
  FROM qvm_new_apps.quotation_vendors qv
  WHERE qv.access_token = p_token;

  IF v_quotation_id IS NULL THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  IF now() > v_expires_at THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;

  RETURN qvm_new_apps.get_vendor_quotation_details(v_quotation_id, v_vendor_id, NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.save_vendor_quotation_by_token(p_token uuid, p_items jsonb, p_part_number_changes jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_quotation_id integer;
  v_vendor_id integer;
  v_quotation_vendor_id bigint;
  v_expires_at timestamptz;
  v_bad_count integer;
BEGIN
  SELECT qv.quotation_id, qv.vendor_id, qv.quotation_vendor_id, qv.token_expires_at
  INTO v_quotation_id, v_vendor_id, v_quotation_vendor_id, v_expires_at
  FROM qvm_new_apps.quotation_vendors qv
  WHERE qv.access_token = p_token;

  IF v_quotation_id IS NULL THEN
    RETURN jsonb_build_object('status', 'not_found');
  END IF;

  IF now() > v_expires_at THEN
    RETURN jsonb_build_object('status', 'expired');
  END IF;

  IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' AND jsonb_array_length(p_items) > 0 THEN
    SELECT count(*) INTO v_bad_count
    FROM jsonb_array_elements(p_items) x
    WHERE NOT EXISTS (
      SELECT 1 FROM qvm_new_apps.quotation_vendor_items qvi
      WHERE qvi.cost_id = (x->>'cost_id')::int
        AND qvi.quotation_vendor_id = v_quotation_vendor_id
    );
    IF v_bad_count > 0 THEN
      RAISE EXCEPTION 'One or more items do not belong to this quotation/vendor';
    END IF;

    PERFORM qvm_new_apps.update_quotation_vendor_items_bulk(p_items);
  END IF;

  -- Vendor-facing part-number edit — same field updates as update_quotation_item_inline, minus
  -- its internal-staff-only auth check (this path is scoped to the vendor's own quotation instead).
  IF p_part_number_changes IS NOT NULL AND jsonb_typeof(p_part_number_changes) = 'array' AND jsonb_array_length(p_part_number_changes) > 0 THEN
    SELECT count(*) INTO v_bad_count
    FROM jsonb_array_elements(p_part_number_changes) x
    WHERE NOT EXISTS (
      SELECT 1 FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_item_id = (x->>'quotation_item_id')::int
        AND qi.quotation_id = v_quotation_id
    );
    IF v_bad_count > 0 THEN
      RAISE EXCEPTION 'One or more items do not belong to this quotation';
    END IF;

    UPDATE qvm_new_apps.quotation_items qi
    SET part_number = COALESCE(NULLIF(x->>'part_number', ''), qi.part_number),
        updated_at = now()
    FROM jsonb_array_elements(p_part_number_changes) x
    WHERE qi.quotation_item_id = (x->>'quotation_item_id')::int;
  END IF;

  PERFORM qvm_new_apps.update_vendor_status(v_quotation_vendor_id);

  RETURN qvm_new_apps.get_vendor_quotation_details(v_quotation_id, v_vendor_id, NULL);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_vendor_quotation_by_token(p_token uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  RETURN qvm_new_apps.get_vendor_quotation_by_token(p_token);
END;
$function$;

CREATE OR REPLACE FUNCTION public.save_vendor_quotation_by_token(p_token uuid, p_items jsonb, p_part_number_changes jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  RETURN qvm_new_apps.save_vendor_quotation_by_token(p_token, p_items, p_part_number_changes);
END;
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.get_vendor_emails(p_vendor_ids integer[], p_vendor_branch_id bigint DEFAULT NULL::bigint)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_emails JSON;
BEGIN
    SELECT json_agg(DISTINCT email) INTO v_emails
    FROM (
        SELECT u.email
        FROM qvm_new_apps.vendors v
        JOIN qvm_new_apps.user_data u ON u.user_id = v.user_id
        WHERE v.vendor_id = ANY(p_vendor_ids)
          AND u.email IS NOT NULL AND u.email <> ''

        UNION

        SELECT u.email
        FROM qvm_new_apps.user_data u
        JOIN qvm_new_apps.list_data ur ON ur.list_data_id = u.user_role
        WHERE u.user_vendor = ANY(p_vendor_ids)
          AND ur.list_data = 'Vendor Admin'
          AND u.email IS NOT NULL AND u.email <> ''

        UNION

        SELECT u.email
        FROM qvm_new_apps.user_data u
        WHERE u.user_vendor = ANY(p_vendor_ids)
          AND u.email IS NOT NULL AND u.email <> ''
          AND (
            p_vendor_branch_id IS NULL
            OR EXISTS (
              SELECT 1 FROM qvm_new_apps.vendor_branch_users vbu
              WHERE vbu.user_id = u.user_id AND vbu.vendor_branch_id = p_vendor_branch_id
            )
          )
    ) e;

    RETURN COALESCE(v_emails, '[]'::json);
END;
$function$;
;
