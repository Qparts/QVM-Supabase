-- Comprehensive branch mapping update using actual data from main branch
-- This maps each email to its correct branch customer ID

UPDATE qvm_new_apps.user_data
SET user_branch = bm.customer_id
FROM (
    SELECT
        email,
        CASE
            -- Petromin West branches
            WHEN email = 'abdulkareem.aliakbar@petromin.com' THEN 2  -- Rabea
            WHEN email = 'adham.aldini@petromin.com' THEN 6  -- Al Murabaland
            WHEN email = 'Ahmed.jamali@petromin.com' THEN 9  -- Al-Safa Land
            WHEN email = 'ahmed.mohamed@petromin.com' THEN 7  -- Al-DahamLand
            WHEN email = 'arshad.k@petromin.com' THEN 5  -- Hamdaniya
            WHEN email = 'deepak.j@petromin.com' THEN 1  -- AlAmal
            WHEN email = 'bassam.sakhnini@petromin.com' THEN 7  -- Al-DahamLand
            WHEN email = 'waleed.abdulghafoor@petromin.com' THEN 1  -- AlAmal
            WHEN email = 'shohidul.islam@petromin.com' THEN 9  -- Al-Safa Land
            WHEN email = 'mohammed.halmi@petromin.com' THEN 1  -- AlAmal
            WHEN email = 'mohammed.khaleel@petromin.com' THEN 5  -- Hamdaniya
            WHEN email = 'mohammed.saad@petromin.com' THEN 8  -- Madinah Arbaeen
            WHEN email = 'o.ghonem@petromin.com' THEN 11  -- Aboor
            WHEN email = 'pac-aboor@petromin.com' THEN 11  -- Aboor
            WHEN email = 'zahidi.joiya@petromin.com' THEN 7  -- Al-DahamLand

            -- Petromin Riyadh branches
            WHEN email = 'a.elbedaly@petromin.com' THEN 10  -- Alkahrj
            WHEN email = 'ahmed.othman@petromin.com' THEN 12  -- Al Duwadimi
            WHEN email = 'arman.iqbal@petromin.com' THEN 6  -- Exit 13
            WHEN email = 'Aminah.alotaibi@petromin.com' THEN 1  -- Masif
            WHEN email = 'atawfik@petromin.com' THEN 13  -- AlQassim
            WHEN email = 'Eyad.fahad@petromin.com' THEN 7  -- Badiya
            WHEN email = 'nawab.zada@petromin.com' THEN 4  -- Al-Malaz
            WHEN email = 's.alromaih@petromin.com' THEN 6  -- Exit 13
            WHEN email = 's.syagha@petromin.com' THEN 4  -- Al-Malaz
            WHEN email = 'wael.ali@petromin.com' THEN 5  -- Khurais
            WHEN email = 'zahid.asghar@petromin.com' THEN 8  -- Exit 14
            WHEN email = 'Ahmed.sayed@petromin.com' THEN 2  -- Thumama

            -- Petromin East branches
            WHEN email = 'A.abueidhah@petromin.com' THEN 1  -- Rashid mall/KHOBAR
            WHEN email = 'ali.akbar@petromin.com' THEN 3  -- Jalawia/DAMMAM
            WHEN email = 'atif.awan@petromin.com' THEN 2  -- Rayan/DAMMAM

            -- Petromin - Body & Paint
            WHEN email = 'abdullah.nadeem@petromin.com' THEN NULL  -- Branch 604 (no customer ID)
            WHEN email = 'amer.aljabari@petromin.com' THEN NULL  -- Asfan (no customer ID)
            WHEN email = 'bilal.sheikh@petromin.com' THEN NULL  -- Qassim 359 (no customer ID)
            WHEN email = 'wael.saeed@petromin.com' THEN NULL  -- Exit 17 (no customer ID)

            -- Petromin Stock (mapped to various customer IDs)
            WHEN email = 'ashwin.kumar@petromin.com' THEN NULL  -- Admin, no specific branch
            WHEN email = 'b.padia@petromin.com' THEN NULL  -- Admin, no specific branch

            -- Saptco branches (no customer IDs in clients_branches)
            WHEN email LIKE '%@saptco.com.sa%' THEN NULL

            -- Other companies (no customer IDs in clients_branches)
            WHEN email = 'Aliao@almajdouie.com' THEN NULL  -- Al Majdouie East
            WHEN email = 'mohammeds@autolead.sa' THEN NULL  -- Al Majdouie Riyadh
            WHEN email = 'Mohammed.AlOssaimi@shaheen-alarabia.com' THEN NULL  -- Jeri Car Services
            WHEN email = 'MW-80101-JCS@joil.com.sa' THEN NULL  -- Jeri Car Services
            WHEN email = 'Mohammed.Ghayasuddin@aljomaihauto.com' THEN NULL  -- AC-DELCO
            WHEN email = 'mohammed.kl@taajeer.com' THEN NULL  -- Motor Lube
            WHEN email = 'sales@smartoneauto.com' THEN NULL  -- Smart One Auto
            WHEN email = 'nsamat2012@hotmail.com' THEN NULL  -- Tawuniya
            WHEN email = 'sales.body@universalcar-sa.com' THEN NULL  -- Tawuniya
            WHEN email = 'dreams8cars@gmail.com' THEN NULL  -- Tawuniya
            WHEN email = 'alaa@universalcar-sa.com' THEN NULL  -- PIT STOP
            WHEN email = 'Mohamad.hamdan@limarcenter.com' THEN NULL  -- Limar El-Shams
            WHEN email = 'pd@alkhadrltd.com' THEN NULL  -- ALKHADR
            WHEN email = 'pm@alkhadrltd.com' THEN NULL  -- ALKHADR
            WHEN email = 'ws.pur@mulhimauto.com' THEN NULL  -- AlMulhim
            WHEN email = 'Turbocare27@gmail.com' THEN NULL  -- Turbo Car Care
            WHEN email = 'Tech-dream@hotmail.com' THEN NULL  -- Dream of Tech
            WHEN email = 'Workshop@gmail.com' THEN NULL  -- Dream of Tech

            -- Qparts team (no branch customer IDs)
            WHEN email LIKE '%@qparts.co' THEN NULL

            -- Unknown/other emails
            ELSE NULL
        END as customer_id
    FROM auth.users
    WHERE email IS NOT NULL
) bm
WHERE qvm_new_apps.user_data.email = bm.email;
