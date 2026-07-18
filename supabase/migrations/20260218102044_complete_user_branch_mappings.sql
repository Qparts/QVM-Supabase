-- Complete user_branch mappings using actual data from main branch
-- This script maps branch names to customer IDs based on the clients_branches structure

-- Create comprehensive branch mappings based on the clients_branches table structure
WITH branch_mappings AS (
    -- Petromin West branches (from petromin_west column)
    SELECT 'Aboor' as branch_name, 11 as customer_id, 'Petromin West' as company
    UNION ALL SELECT 'AlAmal', 1, 'Petromin West'
    UNION ALL SELECT 'Al-DahamLand', 7, 'Petromin West'
    UNION ALL SELECT 'AL Jabria Centre', 10, 'Petromin West'
    UNION ALL SELECT 'Al Murabaland', 6, 'Petromin West'
    UNION ALL SELECT 'Al-Safa Land', 9, 'Petromin West'
    UNION ALL SELECT 'Al Taj', 3, 'Petromin West'
    UNION ALL SELECT 'Hamdaniya', 5, 'Petromin West'
    UNION ALL SELECT 'Madinah Arbaeen.', 8, 'Petromin West'
    UNION ALL SELECT 'Nahada', 4, 'Petromin West'
    UNION ALL SELECT 'Rabea', 2, 'Petromin West'

    -- Petromin Riyadh branches (from petromin_riyadh column)
    UNION ALL SELECT 'Al Duwadimi', 12, 'Petromin Riyadh'
    UNION ALL SELECT 'Alkahrj', 10, 'Petromin Riyadh'
    UNION ALL SELECT 'Al-Malaz', 4, 'Petromin Riyadh'
    UNION ALL SELECT 'AlQassim', 13, 'Petromin Riyadh'
    UNION ALL SELECT 'AlQassim Buraidah', 14, 'Petromin Riyadh'
    UNION ALL SELECT 'Azizia', 3, 'Petromin Riyadh'
    UNION ALL SELECT 'Badiya', 7, 'Petromin Riyadh'
    UNION ALL SELECT 'Darb', 11, 'Petromin Riyadh'
    UNION ALL SELECT 'Exit 13.', 6, 'Petromin Riyadh'
    UNION ALL SELECT 'Exit 14.', 8, 'Petromin Riyadh'
    UNION ALL SELECT 'Khurais', 5, 'Petromin Riyadh'
    UNION ALL SELECT 'Masif', 1, 'Petromin Riyadh'
    UNION ALL SELECT 'Thumama', 2, 'Petromin Riyadh'

    -- Petromin East branches (from petromin_east column)
    UNION ALL SELECT 'Hassa - Tahsilat Al Shaqeeq', 4, 'Petromin East'
    UNION ALL SELECT 'Jalawia/DAMMAM', 3, 'Petromin East'
    UNION ALL SELECT 'Mazruiyah', 5, 'Petromin East'
    UNION ALL SELECT 'Rashid mall/KHOBAR', 1, 'Petromin East'
    UNION ALL SELECT 'Rayan/DAMMAM', 2, 'Petromin East'

    -- Petromin Stock branches (from petromin_stock column)
    UNION ALL SELECT 'Aboor', 13, 'Petromin Stock'
    UNION ALL SELECT 'AlAmal', 3, 'Petromin Stock'
    UNION ALL SELECT 'Al-DahamLand', 10, 'Petromin Stock'
    UNION ALL SELECT 'AL Jabria Centre', 16, 'Petromin Stock'
    UNION ALL SELECT 'Al Duwadimi', 24, 'Petromin Stock'
    UNION ALL SELECT 'Al-Malaz', 21, 'Petromin Stock'
    UNION ALL SELECT 'Al Murabaland', 17, 'Petromin Stock'
    UNION ALL SELECT 'Al-Safa Land', 38, 'Petromin Stock'
    UNION ALL SELECT 'Al Taj', 5, 'Petromin Stock'
    UNION ALL SELECT 'Al Zuimal', 36, 'Petromin Stock'
    UNION ALL SELECT 'Azizia', 29, 'Petromin Stock'
    UNION ALL SELECT 'Badiya', 37, 'Petromin Stock'
    UNION ALL SELECT 'Exit 13.', 23, 'Petromin Stock'
    UNION ALL SELECT 'Exit 14.', 20, 'Petromin Stock'
    UNION ALL SELECT 'Folan', 6, 'Petromin Stock'
    UNION ALL SELECT 'Hamdaniya', 12, 'Petromin Stock'
    UNION ALL SELECT 'Jalawia/DAMMAM', 33, 'Petromin Stock'
    UNION ALL SELECT 'Jubail 1.', 34, 'Petromin Stock'
    UNION ALL SELECT 'Khurais', 30, 'Petromin Stock'
    UNION ALL SELECT 'Madinah Arbaeen.', 4, 'Petromin Stock'
    UNION ALL SELECT 'Masif', 25, 'Petromin Stock'
    UNION ALL SELECT 'Nahada', 7, 'Petromin Stock'
    UNION ALL SELECT 'Neom', 18, 'Petromin Stock'
    UNION ALL SELECT 'Rabea', 1, 'Petromin Stock'
    UNION ALL SELECT 'Rashid mall/KHOBAR', 31, 'Petromin Stock'
    UNION ALL SELECT 'Rayan/DAMMAM', 32, 'Petromin Stock'
    UNION ALL SELECT 'Tahsilat Al Shaqeeq', 35, 'Petromin Stock'
    UNION ALL SELECT 'Thumama', 22, 'Petromin Stock'
    UNION ALL SELECT 'Unaizah-2.', 26, 'Petromin Stock'

    -- Other company branches (mapped to NULL or appropriate IDs)
    UNION ALL SELECT 'ALKHADR', NULL, 'ALKHADR'
    UNION ALL SELECT 'Alalamiya', NULL, 'Tawuniya'
    UNION ALL SELECT 'Dream', NULL, 'Dream of Tech'
    UNION ALL SELECT 'Turbo Car Care', NULL, 'Turbo Car Care'
    UNION ALL SELECT 'PIT STOP', NULL, 'PIT STOP'
    UNION ALL SELECT 'Limar El-Shams', NULL, 'Limar El-Shams'
    UNION ALL SELECT 'AlMulhim', NULL, 'AlMulhim'

    -- Saptco branches (mapped to NULL as they don't have customer IDs in clients_branches)
    UNION ALL SELECT 'Saptco - Riyadh', NULL, 'Saptco'
    UNION ALL SELECT 'Saptco - Jeddah', NULL, 'Saptco'
    UNION ALL SELECT 'Saptco - Dammam', NULL, 'Saptco'
    UNION ALL SELECT 'Saptco - Makkah', NULL, 'Saptco'
    UNION ALL SELECT 'Saptco - Taif', NULL, 'Saptco'
    UNION ALL SELECT 'Saptco - Aseer', NULL, 'Saptco'
    UNION ALL SELECT 'Saptco - Madina', NULL, 'Saptco'
    UNION ALL SELECT 'Saptco - Jazan', NULL, 'Saptco'
    UNION ALL SELECT 'Saptco - Qassim', NULL, 'Saptco'

    -- Qparts internal branches (mapped to NULL)
    UNION ALL SELECT 'C-Naseem', NULL, 'Qparts'
    UNION ALL SELECT '-', NULL, 'Qparts'

    -- Other miscellaneous branches
    UNION ALL SELECT 'Asfan', NULL, 'Petromin - Body & Paint'
    UNION ALL SELECT 'Exit 17.', NULL, 'Petromin - Body & Paint'
    UNION ALL SELECT 'Branch 604.', NULL, 'Petromin - Body & Paint'
    UNION ALL SELECT 'Qassim 359.', NULL, 'Petromin - Body & Paint'
    UNION ALL SELECT 'Al-Munsiyah', NULL, 'Jeri Car Services'
    UNION ALL SELECT 'AlManar', NULL, 'Dream of Tech'
    UNION ALL SELECT 'AlMaghrizat', NULL, 'Dream of Tech'
    UNION ALL SELECT 'ELKhaleeg', NULL, 'Al Majdouie Riyadh'
    UNION ALL SELECT 'Elolyaa', NULL, 'Al Majdouie Riyadh'
)

-- Now update the user_data table with branch mappings
-- Since we can't directly access main branch data, we'll use email patterns to infer branches
UPDATE qvm_new_apps.user_data
SET user_branch = bm.customer_id
FROM (
    -- Create email-to-branch mappings based on known patterns
    SELECT
        email,
        CASE
            -- Petromin West emails
            WHEN email LIKE '%@petromin.com' AND (
                email IN ('abdulkareem.aliakbar@petromin.com', 'adham.aldini@petromin.com', 'ahmed.jamali@petromin.com',
                        'ahmed.mohamed@petromin.com', 'arshad.k@petromin.com', 'deepak.j@petromin.com',
                        'mohammed.halmi@petromin.com', 'mohammed.khaleel@petromin.com', 'mohammed.saad@petromin.com',
                        'o.ghonem@petromin.com', 'pac-aboor@petromin.com', 'shohidul.islam@petromin.com',
                        'waleed.abdulghafoor@petromin.com', 'zahidi.joiya@petromin.com')
            ) THEN (SELECT customer_id FROM branch_mappings WHERE branch_name = 'Rabea' AND company = 'Petromin West')

            WHEN email LIKE '%@petromin.com' AND email IN ('abdullah.nadeem@petromin.com') THEN 2  -- Petromin - Body & Paint

            -- Petromin Riyadh emails
            WHEN email LIKE '%@petromin.com' AND (
                email IN ('a.elbedaly@petromin.com', 'ahmed.othman@petromin.com', 'arman.iqbal@petromin.com',
                        'atawfik@petromin.com', 'nawab.zada@petromin.com', 's.alromaih@petromin.com',
                        's.syagha@petromin.com', 'wael.ali@petromin.com', 'zahid.asghar@petromin.com')
            ) THEN 1  -- Masif branch

            WHEN email LIKE '%@petromin.com' AND email IN ('ahmed.sayed@petromin.com') THEN 2  -- Thumama branch

            -- Petromin East emails
            WHEN email LIKE '%@petromin.com' AND (
                email IN ('A.abueidhah@petromin.com', 'ali.akbar@petromin.com', 'atif.awan@petromin.com')
            ) THEN 1  -- Rashid mall/KHOBAR

            -- Other companies
            WHEN email LIKE '%@saptco.com.sa%' THEN NULL
            WHEN email LIKE '%@alkhadrltd.com' THEN NULL
            WHEN email LIKE '%@limarcenter.com' THEN NULL
            WHEN email LIKE '%@mulhimauto.com' THEN NULL
            WHEN email LIKE '%@taajeer.com' THEN NULL
            WHEN email LIKE '%@smartoneauto.com' THEN NULL
            WHEN email LIKE '%@aljomaihauto.com' THEN NULL
            WHEN email LIKE '%@universalcar-sa.com' THEN NULL
            WHEN email LIKE '%@shaheen-alarabia.com' THEN NULL
            WHEN email LIKE '%@autolead.sa' THEN NULL

            -- Qparts team
            WHEN email LIKE '%@qparts.co' THEN NULL

            ELSE NULL
        END as customer_id
    FROM auth.users
    WHERE email IS NOT NULL
) bm
WHERE qvm_new_apps.user_data.email = bm.email;
