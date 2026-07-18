-- Synced from QVM/test branch applied migration history (version 20260218112150, name: fix_all_remaining_user_names)
-- Fix all remaining users that still have email prefixes instead of proper names

UPDATE qvm_new_apps.user_data 
SET user_name = CASE 
    -- Saptco users
    WHEN email = 'alsenanimn@saptco.com.sa' THEN 'M.N.Alsenani'
    
    -- Petromin users
    WHEN email = 'bassam.sakhnini@petromin.com' THEN 'Bassam Sakhnini'
    WHEN email = 'eyad.fahad@petromin.com' THEN 'Eyad Fahad'
    WHEN email = 'hassan.tariq@petromin.com' THEN 'Hassan Tariq'
    WHEN email = 'jay.galapon@petromin.com' THEN 'Jay Galapon'
    WHEN email = 'joud.fakoush@petromin.com' THEN 'Joud Fakoush'
    WHEN email = 'kalander.mafaz@petromin.com' THEN 'Kalander mafaz'
    WHEN email = 'mahmoud.goudah@petromin.com' THEN 'Mahmoud Goudah'
    WHEN email = 'majed.sayed@petromin.com' THEN 'Majed Sayed'
    WHEN email = 'malik.azhar@petromin.com' THEN 'Malik Azhar'
    WHEN email = 'mohammed.zahid@petromin.com' THEN 'Mohammed Zahid'
    WHEN email = 'm.raoofuddin@petromin.com' THEN 'M raoofuddin'
    WHEN email = 'wael.ali@petromin.com' THEN 'Wael Ali'
    
    -- Other companies
    WHEN email = 'mohamad.hamdan@limarcenter.com' THEN 'Mohamad Hamdan'
    WHEN email = 'mohammed.alossaimi@shaheen-alarabia.com' THEN 'Mohammed AlOssaimi'
    
    -- Keep existing names for others that are already correct
    ELSE user_name
END
WHERE email IN ('alsenanimn@saptco.com.sa', 'bassam.sakhnini@petromin.com', 'eyad.fahad@petromin.com',
                 'hassan.tariq@petromin.com', 'jay.galapon@petromin.com', 'joud.fakoush@petromin.com',
                 'kalander.mafaz@petromin.com', 'mahmoud.goudah@petromin.com', 'majed.sayed@petromin.com',
                 'malik.azhar@petromin.com', 'mohamad.hamdan@limarcenter.com', 'mohammed.alossaimi@shaheen-alarabia.com',
                 'mohammed.zahid@petromin.com', 'm.raoofuddin@petromin.com', 'wael.ali@petromin.com');;
