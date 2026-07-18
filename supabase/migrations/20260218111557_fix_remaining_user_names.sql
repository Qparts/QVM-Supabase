-- Synced from QVM/test branch applied migration history (version 20260218111557, name: fix_remaining_user_names)
-- Fix the remaining users that still have email prefixes instead of proper names

UPDATE qvm_new_apps.user_data 
SET user_name = CASE 
    -- Fix the remaining users with email prefixes
    WHEN email = 'ali.akbar@petromin.com' THEN 'Ali Akbar'
    WHEN email = 'aliao@almajdouie.com' THEN 'Ahmed Omar'
    WHEN email = 'alsheikhmh@saptco.com.sa' THEN 'Mustafa AlSheikh'
    WHEN email = 'aminah.alotaibi@petromin.com' THEN 'Aminah Alotaibi'
    WHEN email = 'waleed.abdulghafoor@petromin.com' THEN 'Waleed Abdulghafoor'
    
    -- Handle the empty name case for mohammeds@autolead.sa
    WHEN email = 'mohammeds@autolead.sa' THEN 'Mohammed Al-Majdouie'
    
    -- Keep existing names for others that are already correct
    ELSE user_name
END
WHERE email IN ('ali.akbar@petromin.com', 'aliao@almajdouie.com', 'alsheikhmh@saptco.com.sa', 
                 'aminah.alotaibi@petromin.com', 'waleed.abdulghafoor@petromin.com',
                 'mohammeds@autolead.sa');;
