-- Synced from QVM/test branch applied migration history (version 20260218144841, name: fix_account_manager_slots_structure)
-- Create agent name to user_id mapping
CREATE TEMP TABLE temp_agent_mapping AS
SELECT 
    user_name as agent_name,
    user_id
FROM qvm_new_apps.user_data
WHERE user_name IN ('دعاء', 'ايمان', 'صلاح', 'براءة', 'Sara Belal', 'Razaz ElFatih', 'ايهاب');

-- Clear existing data
TRUNCATE TABLE qvm_new_apps.account_manager_slots RESTART IDENTITY;

-- Insert one row per account manager per slot (3 rows per manager)
INSERT INTO qvm_new_apps.account_manager_slots (account_manager, saturday, sunday, monday, tuesday, wednesday, thursday, slot_number, is_available, created_at, updated_at)
SELECT 
    user_id as account_manager,
    false as saturday,
    false as sunday, 
    false as monday,
    false as tuesday,
    false as wednesday,
    false as thursday,
    slot_num as slot_number,
    false as is_available,
    NOW() as created_at,
    NOW() as updated_at
FROM temp_agent_mapping
CROSS JOIN (SELECT 1 as slot_num UNION ALL SELECT 2 UNION ALL SELECT 3) slots;

-- Update Saturday availability
UPDATE qvm_new_apps.account_manager_slots ams
SET 
    saturday = true,
    is_available = true
WHERE ams.slot_number = 1 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do1 
    JOIN temp_agent_mapping tam ON do1."Sat_slot 1" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    saturday = true,
    is_available = true
WHERE ams.slot_number = 2 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do2 
    JOIN temp_agent_mapping tam ON do2."Sat_slot 2" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    saturday = true,
    is_available = true
WHERE ams.slot_number = 3 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do3 
    JOIN temp_agent_mapping tam ON do3."Sat_slot 3" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

-- Update Sunday availability
UPDATE qvm_new_apps.account_manager_slots ams
SET 
    sunday = true,
    is_available = true
WHERE ams.slot_number = 1 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do1 
    JOIN temp_agent_mapping tam ON do1."sun_slot 1" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    sunday = true,
    is_available = true
WHERE ams.slot_number = 2 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do2 
    JOIN temp_agent_mapping tam ON do2."sun_slot 2" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    sunday = true,
    is_available = true
WHERE ams.slot_number = 3 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do3 
    JOIN temp_agent_mapping tam ON do3."sun_slot 3" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

-- Update Monday availability
UPDATE qvm_new_apps.account_manager_slots ams
SET 
    monday = true,
    is_available = true
WHERE ams.slot_number = 1 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do1 
    JOIN temp_agent_mapping tam ON do1."mon_slot 1" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    monday = true,
    is_available = true
WHERE ams.slot_number = 2 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do2 
    JOIN temp_agent_mapping tam ON do2."mon_slot 2" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    monday = true,
    is_available = true
WHERE ams.slot_number = 3 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do3 
    JOIN temp_agent_mapping tam ON do3."mon_slot 3" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

-- Update Tuesday availability
UPDATE qvm_new_apps.account_manager_slots ams
SET 
    tuesday = true,
    is_available = true
WHERE ams.slot_number = 1 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do1 
    JOIN temp_agent_mapping tam ON do1."tues_slot 1" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    tuesday = true,
    is_available = true
WHERE ams.slot_number = 2 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do2 
    JOIN temp_agent_mapping tam ON do2."tues_slot 2" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    tuesday = true,
    is_available = true
WHERE ams.slot_number = 3 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do3 
    JOIN temp_agent_mapping tam ON do3."tues_slot 3" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

-- Update Wednesday availability
UPDATE qvm_new_apps.account_manager_slots ams
SET 
    wednesday = true,
    is_available = true
WHERE ams.slot_number = 1 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do1 
    JOIN temp_agent_mapping tam ON do1."wed_slot 1" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    wednesday = true,
    is_available = true
WHERE ams.slot_number = 2 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do2 
    JOIN temp_agent_mapping tam ON do2."wed_slot 2" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    wednesday = true,
    is_available = true
WHERE ams.slot_number = 3 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do3 
    JOIN temp_agent_mapping tam ON do3."wed_slot 3" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

-- Update Thursday availability
UPDATE qvm_new_apps.account_manager_slots ams
SET 
    thursday = true,
    is_available = true
WHERE ams.slot_number = 1 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do1 
    JOIN temp_agent_mapping tam ON do1."thurs_slot 1" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    thursday = true,
    is_available = true
WHERE ams.slot_number = 2 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do2 
    JOIN temp_agent_mapping tam ON do2."thurs_slot 2" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

UPDATE qvm_new_apps.account_manager_slots ams
SET 
    thursday = true,
    is_available = true
WHERE ams.slot_number = 3 AND EXISTS (
    SELECT 1 FROM qvm_new_apps.day_off do3 
    JOIN temp_agent_mapping tam ON do3."thurs_slot 3" = tam.agent_name 
    WHERE tam.user_id = ams.account_manager
);

-- Drop temporary table
DROP TABLE temp_agent_mapping;;
