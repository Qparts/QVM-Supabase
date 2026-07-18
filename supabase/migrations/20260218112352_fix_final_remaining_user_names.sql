-- Synced from QVM/test branch applied migration history (version 20260218112352, name: fix_final_remaining_user_names)
-- Fix the final remaining users that still have email prefixes

UPDATE qvm_new_apps.user_data 
SET user_name = CASE 
    -- Fix the remaining users
    WHEN email = 'jamiasdp@saptco.com.sa' THEN 'D. Jamias'
    WHEN email = 'mohammed.ghayasuddin@aljomaihauto.com' THEN 'Mohammed Ghayasuddin'
    
    -- Keep existing names for others that are already correct
    ELSE user_name
END
WHERE email IN ('jamiasdp@saptco.com.sa', 'mohammed.ghayasuddin@aljomaihauto.com');;
