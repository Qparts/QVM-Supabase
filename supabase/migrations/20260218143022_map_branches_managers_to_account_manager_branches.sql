-- Synced from QVM/test branch applied migration history (version 20260218143022, name: map_branches_managers_to_account_manager_branches)
-- Create a mapping of agent names to user_ids
CREATE TEMP TABLE temp_agent_mapping AS
SELECT 
    user_name as agent_name,
    user_id
FROM qvm_new_apps.user_data
WHERE user_name IN ('دعاء', 'ايمان', 'صلاح', 'براءة', 'Sara Belal', 'Razaz ElFatih', 'ايهاب');

-- Update account_manager_branches based on branches_managers data
UPDATE qvm_new_apps.account_manager_branches amb
SET 
    main_account_manager = CASE 
        WHEN amb.slot_number = 1 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."main agent")
        WHEN amb.slot_number = 2 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."main agent_1")
        WHEN amb.slot_number = 3 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."main agent_2")
    END,
    first_substitute = CASE 
        WHEN amb.slot_number = 1 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."substitute agent")
        WHEN amb.slot_number = 2 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."substitute agent_1")
        WHEN amb.slot_number = 3 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."substitute agent_2")
    END,
    second_substitute = CASE 
        WHEN amb.slot_number = 1 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."2nd substitute agent")
        WHEN amb.slot_number = 2 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."2nd substitute agent_1")
        WHEN amb.slot_number = 3 THEN (SELECT user_id FROM temp_agent_mapping WHERE agent_name = bm."2nd substitute agent_2")
    END
FROM qvm_new_apps.client_branches cb
JOIN qvm_new_apps.branches_managers bm ON LOWER(TRIM(cb.branch_name)) = LOWER(TRIM(bm."branch name"))
WHERE amb.customer_id = cb.customer_id;

-- Drop temporary table
DROP TABLE temp_agent_mapping;;
