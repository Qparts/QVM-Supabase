-- Synced from QVM/test branch applied migration history (version 20260218144223, name: populate_account_manager_slots_from_day_off)
-- Create agent name to user_id mapping
CREATE TEMP TABLE temp_agent_mapping AS
SELECT 
    user_name as agent_name,
    user_id
FROM qvm_new_apps.user_data
WHERE user_name IN ('دعاء', 'ايمان', 'صلاح', 'براءة', 'Sara Belal', 'Razaz ElFatih', 'ايهاب');

-- Clear existing data
TRUNCATE TABLE qvm_new_apps.account_manager_slots RESTART IDENTITY;

-- Insert all slot assignments in a single query
INSERT INTO qvm_new_apps.account_manager_slots (account_manager, saturday, sunday, monday, tuesday, wednesday, thursday, slot_number, is_available, created_at, updated_at)
SELECT 
    (SELECT user_id FROM temp_agent_mapping WHERE agent_name = slot_value) as account_manager,
    CASE WHEN day_name = 'Saturday' THEN true ELSE false END as saturday,
    CASE WHEN day_name = 'Sunday' THEN true ELSE false END as sunday,
    CASE WHEN day_name = 'Monday' THEN true ELSE false END as monday,
    CASE WHEN day_name = 'Tuesday' THEN true ELSE false END as tuesday,
    CASE WHEN day_name = 'Wednesday' THEN true ELSE false END as wednesday,
    CASE WHEN day_name = 'Thursday' THEN true ELSE false END as thursday,
    slot_num as slot_number,
    true as is_available,
    NOW() as created_at,
    NOW() as updated_at
FROM (
    -- Unpivot the day_off table to get all slot assignments
    SELECT 'Saturday' as day_name, 1 as slot_num, "Sat_slot 1" as slot_value FROM qvm_new_apps.day_off WHERE "Sat_slot 1" IS NOT NULL AND TRIM("Sat_slot 1") <> ''
    UNION ALL
    SELECT 'Saturday', 2, "Sat_slot 2" FROM qvm_new_apps.day_off WHERE "Sat_slot 2" IS NOT NULL AND TRIM("Sat_slot 2") <> ''
    UNION ALL
    SELECT 'Saturday', 3, "Sat_slot 3" FROM qvm_new_apps.day_off WHERE "Sat_slot 3" IS NOT NULL AND TRIM("Sat_slot 3") <> ''
    UNION ALL
    SELECT 'Sunday', 1, "sun_slot 1" FROM qvm_new_apps.day_off WHERE "sun_slot 1" IS NOT NULL AND TRIM("sun_slot 1") <> ''
    UNION ALL
    SELECT 'Sunday', 2, "sun_slot 2" FROM qvm_new_apps.day_off WHERE "sun_slot 2" IS NOT NULL AND TRIM("sun_slot 2") <> ''
    UNION ALL
    SELECT 'Sunday', 3, "sun_slot 3" FROM qvm_new_apps.day_off WHERE "sun_slot 3" IS NOT NULL AND TRIM("sun_slot 3") <> ''
    UNION ALL
    SELECT 'Monday', 1, "mon_slot 1" FROM qvm_new_apps.day_off WHERE "mon_slot 1" IS NOT NULL AND TRIM("mon_slot 1") <> ''
    UNION ALL
    SELECT 'Monday', 2, "mon_slot 2" FROM qvm_new_apps.day_off WHERE "mon_slot 2" IS NOT NULL AND TRIM("mon_slot 2") <> ''
    UNION ALL
    SELECT 'Monday', 3, "mon_slot 3" FROM qvm_new_apps.day_off WHERE "mon_slot 3" IS NOT NULL AND TRIM("mon_slot 3") <> ''
    UNION ALL
    SELECT 'Tuesday', 1, "tues_slot 1" FROM qvm_new_apps.day_off WHERE "tues_slot 1" IS NOT NULL AND TRIM("tues_slot 1") <> ''
    UNION ALL
    SELECT 'Tuesday', 2, "tues_slot 2" FROM qvm_new_apps.day_off WHERE "tues_slot 2" IS NOT NULL AND TRIM("tues_slot 2") <> ''
    UNION ALL
    SELECT 'Tuesday', 3, "tues_slot 3" FROM qvm_new_apps.day_off WHERE "tues_slot 3" IS NOT NULL AND TRIM("tues_slot 3") <> ''
    UNION ALL
    SELECT 'Wednesday', 1, "wed_slot 1" FROM qvm_new_apps.day_off WHERE "wed_slot 1" IS NOT NULL AND TRIM("wed_slot 1") <> ''
    UNION ALL
    SELECT 'Wednesday', 2, "wed_slot 2" FROM qvm_new_apps.day_off WHERE "wed_slot 2" IS NOT NULL AND TRIM("wed_slot 2") <> ''
    UNION ALL
    SELECT 'Wednesday', 3, "wed_slot 3" FROM qvm_new_apps.day_off WHERE "wed_slot 3" IS NOT NULL AND TRIM("wed_slot 3") <> ''
    UNION ALL
    SELECT 'Thursday', 1, "thurs_slot 1" FROM qvm_new_apps.day_off WHERE "thurs_slot 1" IS NOT NULL AND TRIM("thurs_slot 1") <> ''
    UNION ALL
    SELECT 'Thursday', 2, "thurs_slot 2" FROM qvm_new_apps.day_off WHERE "thurs_slot 2" IS NOT NULL AND TRIM("thurs_slot 2") <> ''
    UNION ALL
    SELECT 'Thursday', 3, "thurs_slot 3" FROM qvm_new_apps.day_off WHERE "thurs_slot 3" IS NOT NULL AND TRIM("thurs_slot 3") <> ''
) slot_assignments
WHERE slot_value IS NOT NULL;

-- Drop temporary table
DROP TABLE temp_agent_mapping;;
