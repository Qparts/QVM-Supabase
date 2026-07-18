-- Synced from QVM/test branch applied migration history (version 20260218150000, name: populate_account_manager_allocations)
-- Update account_manager_allocations based on availability hierarchy
-- Priority: main_account_manager -> first_substitute -> second_substitute -> fallback_account_manager

UPDATE qvm_new_apps.account_manager_allocations ama
SET 
    saturday = COALESCE(
        -- Try main account manager if available on Saturday
        CASE WHEN ams_main.saturday AND ams_main.slot_number = ama.slot_number THEN amb.main_account_manager END,
        -- Try first substitute if main is not available
        CASE WHEN ams_first.saturday AND ams_first.slot_number = ama.slot_number THEN amb.first_substitute END,
        -- Try second substitute if first is not available
        CASE WHEN ams_second.saturday AND ams_second.slot_number = ama.slot_number THEN amb.second_substitute END,
        -- Try fallback if none of the above are available
        amb.fallback_account_manager
    ),
    sunday = COALESCE(
        CASE WHEN ams_main.sunday AND ams_main.slot_number = ama.slot_number THEN amb.main_account_manager END,
        CASE WHEN ams_first.sunday AND ams_first.slot_number = ama.slot_number THEN amb.first_substitute END,
        CASE WHEN ams_second.sunday AND ams_second.slot_number = ama.slot_number THEN amb.second_substitute END,
        amb.fallback_account_manager
    ),
    monday = COALESCE(
        CASE WHEN ams_main.monday AND ams_main.slot_number = ama.slot_number THEN amb.main_account_manager END,
        CASE WHEN ams_first.monday AND ams_first.slot_number = ama.slot_number THEN amb.first_substitute END,
        CASE WHEN ams_second.monday AND ams_second.slot_number = ama.slot_number THEN amb.second_substitute END,
        amb.fallback_account_manager
    ),
    tuesday = COALESCE(
        CASE WHEN ams_main.tuesday AND ams_main.slot_number = ama.slot_number THEN amb.main_account_manager END,
        CASE WHEN ams_first.tuesday AND ams_first.slot_number = ama.slot_number THEN amb.first_substitute END,
        CASE WHEN ams_second.tuesday AND ams_second.slot_number = ama.slot_number THEN amb.second_substitute END,
        amb.fallback_account_manager
    ),
    wednesday = COALESCE(
        CASE WHEN ams_main.wednesday AND ams_main.slot_number = ama.slot_number THEN amb.main_account_manager END,
        CASE WHEN ams_first.wednesday AND ams_first.slot_number = ama.slot_number THEN amb.first_substitute END,
        CASE WHEN ams_second.wednesday AND ams_second.slot_number = ama.slot_number THEN amb.second_substitute END,
        amb.fallback_account_manager
    ),
    thursday = COALESCE(
        CASE WHEN ams_main.thursday AND ams_main.slot_number = ama.slot_number THEN amb.main_account_manager END,
        CASE WHEN ams_first.thursday AND ams_first.slot_number = ama.slot_number THEN amb.first_substitute END,
        CASE WHEN ams_second.thursday AND ams_second.slot_number = ama.slot_number THEN amb.second_substitute END,
        amb.fallback_account_manager
    ),
    calculated_at = NOW()
FROM qvm_new_apps.account_manager_branches amb
LEFT JOIN qvm_new_apps.account_manager_slots ams_main ON amb.main_account_manager = ams_main.account_manager
LEFT JOIN qvm_new_apps.account_manager_slots ams_first ON amb.first_substitute = ams_first.account_manager  
LEFT JOIN qvm_new_apps.account_manager_slots ams_second ON amb.second_substitute = ams_second.account_manager
WHERE amb.customer_id = ama.customer_id 
  AND amb.slot_number = ama.slot_number;;
