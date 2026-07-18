-- Synced from QVM/test branch applied migration history (version 20260218150955, name: fix_account_manager_allocations_mapping)
-- Clear existing allocations
TRUNCATE TABLE qvm_new_apps.account_manager_allocations RESTART IDENTITY;

-- Re-populate with correct mapping logic
-- For each branch/slot, check main manager availability first, then substitutes
INSERT INTO qvm_new_apps.account_manager_allocations (customer_id, slot_number, saturday, sunday, monday, tuesday, wednesday, thursday, calculated_at)
SELECT 
    amb.customer_id,
    amb.slot_number,
    -- Saturday: Check main first, then first_sub, then second_sub
    CASE 
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.main_account_manager AND ams.slot_number = amb.slot_number AND ams.saturday = true)
        THEN amb.main_account_manager
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.first_substitute AND ams.slot_number = amb.slot_number AND ams.saturday = true)
        THEN amb.first_substitute
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.second_substitute AND ams.slot_number = amb.slot_number AND ams.saturday = true)
        THEN amb.second_substitute
        ELSE amb.fallback_account_manager
    END as saturday,
    -- Sunday: Check main first, then first_sub, then second_sub
    CASE 
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.main_account_manager AND ams.slot_number = amb.slot_number AND ams.sunday = true)
        THEN amb.main_account_manager
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.first_substitute AND ams.slot_number = amb.slot_number AND ams.sunday = true)
        THEN amb.first_substitute
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.second_substitute AND ams.slot_number = amb.slot_number AND ams.sunday = true)
        THEN amb.second_substitute
        ELSE amb.fallback_account_manager
    END as sunday,
    -- Monday: Check main first, then first_sub, then second_sub
    CASE 
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.main_account_manager AND ams.slot_number = amb.slot_number AND ams.monday = true)
        THEN amb.main_account_manager
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.first_substitute AND ams.slot_number = amb.slot_number AND ams.monday = true)
        THEN amb.first_substitute
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.second_substitute AND ams.slot_number = amb.slot_number AND ams.monday = true)
        THEN amb.second_substitute
        ELSE amb.fallback_account_manager
    END as monday,
    -- Tuesday: Check main first, then first_sub, then second_sub
    CASE 
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.main_account_manager AND ams.slot_number = amb.slot_number AND ams.tuesday = true)
        THEN amb.main_account_manager
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.first_substitute AND ams.slot_number = amb.slot_number AND ams.tuesday = true)
        THEN amb.first_substitute
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.second_substitute AND ams.slot_number = amb.slot_number AND ams.tuesday = true)
        THEN amb.second_substitute
        ELSE amb.fallback_account_manager
    END as tuesday,
    -- Wednesday: Check main first, then first_sub, then second_sub
    CASE 
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.main_account_manager AND ams.slot_number = amb.slot_number AND ams.wednesday = true)
        THEN amb.main_account_manager
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.first_substitute AND ams.slot_number = amb.slot_number AND ams.wednesday = true)
        THEN amb.first_substitute
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.second_substitute AND ams.slot_number = amb.slot_number AND ams.wednesday = true)
        THEN amb.second_substitute
        ELSE amb.fallback_account_manager
    END as wednesday,
    -- Thursday: Check main first, then first_sub, then second_sub
    CASE 
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.main_account_manager AND ams.slot_number = amb.slot_number AND ams.thursday = true)
        THEN amb.main_account_manager
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.first_substitute AND ams.slot_number = amb.slot_number AND ams.thursday = true)
        THEN amb.first_substitute
        WHEN EXISTS(SELECT 1 FROM qvm_new_apps.account_manager_slots ams WHERE ams.account_manager = amb.second_substitute AND ams.slot_number = amb.slot_number AND ams.thursday = true)
        THEN amb.second_substitute
        ELSE amb.fallback_account_manager
    END as thursday,
    NOW() as calculated_at
FROM qvm_new_apps.account_manager_branches amb
WHERE amb.main_account_manager IS NOT NULL
   OR amb.first_substitute IS NOT NULL
   OR amb.second_substitute IS NOT NULL;;
