-- Synced from QVM/test branch applied migration history (version 20260602132842, name: qpd_fix_reassign_orders_allocation_branch_lookup)
BEGIN;

SET search_path TO qvm_new_apps, public;

CREATE OR REPLACE FUNCTION public.reassign_orders_allocation_rpc(
  p_quotation_ids integer[],
  p_user_id text,
  p_current_slot smallint DEFAULT 1,
  p_reference_at timestamptz DEFAULT now(),
  p_shift_handover_at time DEFAULT '16:00:00'::time,
  p_timezone text DEFAULT 'Asia/Riyadh',
  p_max_active_orders integer DEFAULT 7
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps','public'
AS $function$
DECLARE
  v_outgoing_manager uuid;
  v_total_quotations integer := COALESCE(array_length(p_quotation_ids, 1), 0);
  v_eligible_quotations integer := 0;
  v_reassigned_count integer := 0;
  v_active_status_ids integer[] := ARRAY[15, 16, 17, 19, 21, 22, 23, 24, 25, 28, 29, 213, 214, 215];
  v_local_ts timestamp;
  v_local_date date;
  v_local_time time;
  v_primary_slot smallint;
  v_next_slot smallint;
  v_selected_slot smallint;
  v_debug jsonb := '[]'::jsonb;
  v_pending_loads jsonb := '{}'::jsonb;

  v_quotation record;
  v_has_active_items boolean;
  v_allocated_manager uuid;
  v_slot_manager uuid;
  v_main_manager uuid;
  v_first_substitute uuid;
  v_second_substitute uuid;
  v_new_manager uuid;
  v_candidate uuid;
  v_candidate_order uuid[] := ARRAY[]::uuid[];
  v_candidate_debug jsonb;
  v_candidate_debug_list jsonb;
  v_existing_active_count integer;
  v_pending_for_candidate integer;
  v_effective_active_count integer;
  v_is_available boolean;
  v_quotation_debug jsonb;
BEGIN
  IF p_quotation_ids IS NULL OR array_length(p_quotation_ids, 1) IS NULL OR array_length(p_quotation_ids, 1) = 0 THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'Please Select the items/Orders You want to reassign.',
      'reassigned_count', 0
    );
  END IF;

  IF p_current_slot NOT BETWEEN 1 AND 3 THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'Current slot must be 1, 2, or 3.',
      'reassigned_count', 0
    );
  END IF;

  IF p_max_active_orders < 1 THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'Maximum active orders threshold must be at least 1.',
      'reassigned_count', 0
    );
  END IF;

  SELECT user_id
  INTO v_outgoing_manager
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id::uuid
  LIMIT 1;

  IF v_outgoing_manager IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'User not found or not an account manager.',
      'reassigned_count', 0,
      'debug', jsonb_build_object('provided_user_id', p_user_id)
    );
  END IF;

  v_local_ts := p_reference_at AT TIME ZONE p_timezone;
  v_local_date := v_local_ts::date;
  v_local_time := v_local_ts::time;

  v_primary_slot := CASE
    WHEN v_local_time >= p_shift_handover_at THEN LEAST(3, p_current_slot + 1)
    ELSE p_current_slot
  END;

  v_next_slot := CASE
    WHEN v_primary_slot < 3 THEN v_primary_slot + 1
    ELSE NULL
  END;

  FOR v_quotation IN
    SELECT
      q.quotation_id,
      q.account_manager,
      branch_lookup.customer_id AS branch_id
    FROM qvm_new_apps.quotations q
    LEFT JOIN LATERAL (
      SELECT qi.customer_id
      FROM qvm_new_apps.quotation_items qi
      WHERE qi.quotation_id = q.quotation_id
        AND qi.customer_id IS NOT NULL
      ORDER BY qi.quotation_item_id
      LIMIT 1
    ) AS branch_lookup ON true
    WHERE q.quotation_id = ANY(p_quotation_ids)
    ORDER BY q.quotation_id
  LOOP
    v_quotation_debug := jsonb_build_object(
      'quotation_id', v_quotation.quotation_id,
      'branch_id', v_quotation.branch_id,
      'outgoing_manager', v_outgoing_manager,
      'current_account_manager', v_quotation.account_manager,
      'primary_slot', v_primary_slot,
      'next_slot', v_next_slot
    );

    IF v_quotation.account_manager IS DISTINCT FROM v_outgoing_manager THEN
      v_debug := v_debug || jsonb_build_array(
        v_quotation_debug || jsonb_build_object(
          'reassigned', false,
          'reason', 'not_owned_by_outgoing_manager'
        )
      );
      CONTINUE;
    END IF;

    IF v_quotation.branch_id IS NULL THEN
      v_debug := v_debug || jsonb_build_array(
        v_quotation_debug || jsonb_build_object(
          'reassigned', false,
          'reason', 'quotation_has_no_branch_customer_id'
        )
      );
      CONTINUE;
    END IF;

    SELECT EXISTS (
      SELECT 1
      FROM qvm_new_apps.quotation_items qi
      LEFT JOIN qvm_new_apps.confirmed_items ci
        ON ci.quotation_item_id = qi.quotation_item_id
      WHERE qi.quotation_id = v_quotation.quotation_id
        AND COALESCE(ci.item_status, qi.item_status) = ANY(v_active_status_ids)
    )
    INTO v_has_active_items;

    IF NOT v_has_active_items THEN
      v_debug := v_debug || jsonb_build_array(
        v_quotation_debug || jsonb_build_object(
          'reassigned', false,
          'reason', 'quotation_has_no_active_items'
        )
      );
      CONTINUE;
    END IF;

    v_eligible_quotations := v_eligible_quotations + 1;
    v_selected_slot := v_primary_slot;
    v_allocated_manager := NULL;

    SELECT
      CASE EXTRACT(DOW FROM v_local_date)
        WHEN 6 THEN ama.saturday
        WHEN 0 THEN ama.sunday
        WHEN 1 THEN ama.monday
        WHEN 2 THEN ama.tuesday
        WHEN 3 THEN ama.wednesday
        WHEN 4 THEN ama.thursday
        ELSE NULL::uuid
      END
    INTO v_allocated_manager
    FROM qvm_new_apps.account_manager_allocations ama
    WHERE ama.customer_id = v_quotation.branch_id
      AND ama.slot_number = v_selected_slot
    LIMIT 1;

    IF (v_allocated_manager IS NULL OR v_allocated_manager = v_outgoing_manager)
      AND v_next_slot IS NOT NULL
    THEN
      SELECT
        CASE EXTRACT(DOW FROM v_local_date)
          WHEN 6 THEN ama.saturday
          WHEN 0 THEN ama.sunday
          WHEN 1 THEN ama.monday
          WHEN 2 THEN ama.tuesday
          WHEN 3 THEN ama.wednesday
          WHEN 4 THEN ama.thursday
          ELSE NULL::uuid
        END
      INTO v_slot_manager
      FROM qvm_new_apps.account_manager_allocations ama
      WHERE ama.customer_id = v_quotation.branch_id
        AND ama.slot_number = v_next_slot
      LIMIT 1;

      IF v_slot_manager IS NOT NULL THEN
        v_allocated_manager := v_slot_manager;
        v_selected_slot := v_next_slot;
      END IF;
    END IF;

    SELECT
      MAX(CASE WHEN amb.slot_number = v_selected_slot THEN amb.main_account_manager END),
      MAX(CASE WHEN amb.slot_number = v_selected_slot THEN amb.first_substitute END),
      MAX(CASE WHEN amb.slot_number = v_selected_slot THEN amb.second_substitute END)
    INTO v_main_manager, v_first_substitute, v_second_substitute
    FROM qvm_new_apps.account_manager_branches amb
    WHERE amb.customer_id = v_quotation.branch_id;

    v_candidate_order := ARRAY[]::uuid[];

    IF v_allocated_manager IS NOT NULL THEN
      v_candidate_order := array_append(v_candidate_order, v_allocated_manager);
    END IF;

    FOREACH v_candidate IN ARRAY ARRAY[v_main_manager, v_first_substitute, v_second_substitute]
    LOOP
      IF v_candidate IS NULL OR v_candidate = v_outgoing_manager THEN
        CONTINUE;
      END IF;

      IF v_candidate = ANY(v_candidate_order) THEN
        CONTINUE;
      END IF;

      v_candidate_order := array_append(v_candidate_order, v_candidate);
    END LOOP;

    v_new_manager := NULL;
    v_candidate_debug_list := '[]'::jsonb;

    FOREACH v_candidate IN ARRAY v_candidate_order
    LOOP
      v_is_available := public._am_is_available(v_candidate, v_selected_slot, v_local_date);

      SELECT COUNT(DISTINCT q.quotation_id)
      INTO v_existing_active_count
      FROM qvm_new_apps.quotations q
      WHERE q.account_manager = v_candidate
        AND EXISTS (
          SELECT 1
          FROM qvm_new_apps.quotation_items qi
          LEFT JOIN qvm_new_apps.confirmed_items ci
            ON ci.quotation_item_id = qi.quotation_item_id
          WHERE qi.quotation_id = q.quotation_id
            AND COALESCE(ci.item_status, qi.item_status) = ANY(v_active_status_ids)
        );

      v_pending_for_candidate := COALESCE((v_pending_loads ->> v_candidate::text)::integer, 0);
      v_effective_active_count := v_existing_active_count + v_pending_for_candidate;

      v_candidate_debug := jsonb_build_object(
        'candidate', v_candidate,
        'slot_number', v_selected_slot,
        'available', v_is_available,
        'existing_active_quotations', v_existing_active_count,
        'pending_batch_assignments', v_pending_for_candidate,
        'effective_active_quotations', v_effective_active_count,
        'under_capacity', v_effective_active_count <= p_max_active_orders
      );

      v_candidate_debug_list := v_candidate_debug_list || jsonb_build_array(v_candidate_debug);

      IF v_is_available AND v_effective_active_count <= p_max_active_orders THEN
        v_new_manager := v_candidate;
        EXIT;
      END IF;
    END LOOP;

    IF v_new_manager IS NULL THEN
      v_debug := v_debug || jsonb_build_array(
        v_quotation_debug || jsonb_build_object(
          'allocated_manager', v_allocated_manager,
          'selected_slot', v_selected_slot,
          'evaluated_candidates', v_candidate_debug_list,
          'reassigned', false,
          'reason', 'no_available_under_capacity_manager_found'
        )
      );
      CONTINUE;
    END IF;

    UPDATE qvm_new_apps.quotations
    SET account_manager = v_new_manager
    WHERE quotation_id = v_quotation.quotation_id;

    INSERT INTO qvm_new_apps.quotation_account_managers (
      quotation_id,
      assigned_from,
      assigned_to,
      created_at
    )
    VALUES (
      v_quotation.quotation_id,
      v_outgoing_manager,
      v_new_manager,
      NOW()
    );

    v_pending_loads := jsonb_set(
      v_pending_loads,
      ARRAY[v_new_manager::text],
      to_jsonb(COALESCE((v_pending_loads ->> v_new_manager::text)::integer, 0) + 1),
      true
    );

    v_reassigned_count := v_reassigned_count + 1;

    v_debug := v_debug || jsonb_build_array(
      v_quotation_debug || jsonb_build_object(
        'allocated_manager', v_allocated_manager,
        'selected_slot', v_selected_slot,
        'evaluated_candidates', v_candidate_debug_list,
        'selected_manager', v_new_manager,
        'reassigned', true
      )
    );
  END LOOP;

  IF v_reassigned_count = 0 THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'No active RFQs/Orders could be reassigned using the allocation logic.',
      'reassigned_count', 0,
      'debug', jsonb_build_object(
        'current_slot', p_current_slot,
        'primary_slot_used', v_primary_slot,
        'next_slot_available', v_next_slot,
        'local_date', v_local_date,
        'local_time', v_local_time,
        'evaluations', v_debug
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'status',
    CASE
      WHEN v_reassigned_count = v_eligible_quotations THEN 'success'
      ELSE 'partial'
    END,
    'message',
    CASE
      WHEN v_reassigned_count = v_eligible_quotations THEN
        'Active RFQs/Orders successfully reassigned using allocation logic.'
      ELSE
        format(
          'Reassigned %s of %s eligible active RFQs/Orders using allocation logic.',
          v_reassigned_count,
          v_eligible_quotations
        )
    END,
    'reassigned_count', v_reassigned_count,
    'eligible_count', v_eligible_quotations,
    'total_quotations_provided', v_total_quotations,
    'debug', jsonb_build_object(
      'current_slot', p_current_slot,
      'primary_slot_used', v_primary_slot,
      'next_slot_available', v_next_slot,
      'local_date', v_local_date,
      'local_time', v_local_time,
      'evaluations', v_debug
    )
  );
END;
$function$;

COMMIT;;
