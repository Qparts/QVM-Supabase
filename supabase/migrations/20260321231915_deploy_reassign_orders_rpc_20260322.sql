-- Synced from QVM/test branch applied migration history (version 20260321231915, name: deploy_reassign_orders_rpc_20260322)
BEGIN;

CREATE OR REPLACE FUNCTION public.reassign_orders_rpc(
  p_quotation_ids integer[],
  p_user_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_current_manager_id uuid;
  v_quotation record;
  v_new_manager uuid;
  v_reassigned_count integer := 0;
  v_active_quotations integer[] := ARRAY[]::integer[];
  v_has_active_items boolean;
  v_branch_id bigint;
  v_debug jsonb := '[]'::jsonb;
  v_quotation_debug jsonb;
  v_total_quotations integer := 0;
  v_owned_quotations integer := 0;
BEGIN
  -- Validate user exists and get their user_id (which IS the account manager ID)
  SELECT user_id INTO v_current_manager_id
  FROM qvm_new_apps.user_data
  WHERE user_id = p_user_id::uuid
  LIMIT 1;

  IF v_current_manager_id IS NULL THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'User not found or not an account manager.',
      'reassigned_count', 0,
      'debug', jsonb_build_object('provided_user_id', p_user_id)
    );
  END IF;

  -- Count total quotations provided
  v_total_quotations := array_length(p_quotation_ids, 1);

  -- Validate quotations belong to this manager and have active items
  FOR v_quotation IN 
    SELECT q.quotation_id, q.account_manager
    FROM qvm_new_apps.quotations q
    WHERE q.quotation_id = ANY(p_quotation_ids)
  LOOP
    v_quotation_debug := jsonb_build_object(
      'quotation_id', v_quotation.quotation_id,
      'account_manager', v_quotation.account_manager,
      'current_manager', v_current_manager_id,
      'is_owned', v_quotation.account_manager = v_current_manager_id
    );

    -- Check ownership
    IF v_quotation.account_manager = v_current_manager_id THEN
      v_owned_quotations := v_owned_quotations + 1;
      
      -- Check if quotation has active items (not in blocked statuses: 18,20,23,25,26,27,30,31,215)
      SELECT EXISTS(
        SELECT 1 FROM qvm_new_apps.quotation_items
        WHERE quotation_id = v_quotation.quotation_id
          AND item_status NOT IN (18, 20, 23, 25, 26, 27, 30, 31, 215)
      ) INTO v_has_active_items;

      v_quotation_debug := v_quotation_debug || jsonb_build_object('has_active_items', v_has_active_items);

      IF v_has_active_items THEN
        v_active_quotations := array_append(v_active_quotations, v_quotation.quotation_id);
        v_quotation_debug := v_quotation_debug || jsonb_build_object('added_to_active', true);
      ELSE
        v_quotation_debug := v_quotation_debug || jsonb_build_object('added_to_active', false, 'reason', 'no_active_items');
      END IF;
    ELSE
      v_quotation_debug := v_quotation_debug || jsonb_build_object('added_to_active', false, 'reason', 'not_owned');
    END IF;

    v_debug := v_debug || jsonb_build_array(v_quotation_debug);
  END LOOP;

  IF array_length(v_active_quotations, 1) IS NULL OR array_length(v_active_quotations, 1) = 0 THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'No active orders assigned to you were found.',
      'reassigned_count', 0,
      'debug', jsonb_build_object(
        'current_manager_id', v_current_manager_id,
        'total_quotations_provided', v_total_quotations,
        'owned_quotations', v_owned_quotations,
        'active_quotations_count', COALESCE(array_length(v_active_quotations, 1), 0),
        'quotations', v_debug
      )
    );
  END IF;

  -- Reassign each active quotation
  FOR v_quotation IN 
    SELECT q.quotation_id
    FROM qvm_new_apps.quotations q
    WHERE q.quotation_id = ANY(v_active_quotations)
  LOOP
    -- Get the branch from the first item in this quotation
    SELECT customer_id INTO v_branch_id
    FROM qvm_new_apps.quotation_items
    WHERE quotation_id = v_quotation.quotation_id
    LIMIT 1;

    -- Find substitute manager for this branch
    v_new_manager := NULL;
    
    IF v_branch_id IS NOT NULL THEN
      SELECT 
        CASE 
          WHEN main_account_manager = v_current_manager_id THEN 
            COALESCE(first_substitute, second_substitute, fallback_account_manager)
          WHEN first_substitute = v_current_manager_id THEN 
            COALESCE(main_account_manager, second_substitute, fallback_account_manager)
          WHEN second_substitute = v_current_manager_id THEN 
            COALESCE(main_account_manager, first_substitute, fallback_account_manager)
          ELSE 
            COALESCE(main_account_manager, first_substitute, second_substitute, fallback_account_manager)
        END INTO v_new_manager
      FROM qvm_new_apps.account_manager_branches
      WHERE customer_id = v_branch_id
      LIMIT 1;
    END IF;

    -- Fallback if no manager found or same manager
    IF v_new_manager IS NULL OR v_new_manager = v_current_manager_id THEN
      -- Get any other account manager as fallback
      SELECT user_id INTO v_new_manager
      FROM qvm_new_apps.user_data
      WHERE user_id != v_current_manager_id
      LIMIT 1;
    END IF;

    -- Skip if still no manager found
    IF v_new_manager IS NULL THEN
      CONTINUE;
    END IF;

    -- Update quotation
    UPDATE qvm_new_apps.quotations
    SET account_manager = v_new_manager
    WHERE quotation_id = v_quotation.quotation_id;

    -- Log reassignment
    INSERT INTO qvm_new_apps.quotation_account_managers (
      quotation_id,
      assigned_from,
      assigned_to,
      created_at
    ) VALUES (
      v_quotation.quotation_id,
      v_current_manager_id,
      v_new_manager,
      NOW()
    );

    v_reassigned_count := v_reassigned_count + 1;
  END LOOP;

  IF v_reassigned_count = 0 THEN
    RETURN jsonb_build_object(
      'status', 'error',
      'message', 'No orders could be reassigned.',
      'reassigned_count', 0
    );
  END IF;

  RETURN jsonb_build_object(
    'status', 'success',
    'message', 'Active orders successfully reassigned to the next available Account Manager.',
    'reassigned_count', v_reassigned_count
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.reassign_orders_rpc(integer[], text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.reassign_orders_rpc(integer[], text) TO authenticated;

COMMIT;;
