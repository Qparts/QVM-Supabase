-- Synced from QVM/test branch applied migration history (version 20260218110935, name: complete_branch_mappings_with_existing_data)
-- Complete branch mappings using the actual customer IDs from client_branches table

UPDATE qvm_new_apps.user_data 
SET user_branch = CASE 
    -- ALKHADR
    WHEN email IN ('pd@alkhadrltd.com', 'pm@alkhadrltd.com') THEN 90
    
    -- Al Majdouie branches
    WHEN email = 'Aliao@almajdouie.com' THEN 50  -- Al Rakah
    WHEN email LIKE '%@autolead.sa' AND email LIKE '%khaleeg%' THEN 48  -- ELKhaleeg
    WHEN email LIKE '%@autolead.sa' AND email LIKE '%olyaa%' THEN 49  -- Elolyaa
    WHEN email = 'mahadeer@autolead.sa' THEN NULL  -- Maj-Khurais not found
    
    -- AlMulhim
    WHEN email = 'ws.pur@mulhimauto.com' THEN 88
    
    -- Caraagy West / Qparts
    WHEN email = 'alaa.khedr@qparts.co' THEN NULL  -- C-Naseem not found
    
    -- Carshub
    WHEN email = 'info@carshubksa.com' THEN 91  -- Exit 18-
    
    -- Dream of Tech
    WHEN email = 'Workshop@gmail.com' THEN 93  -- AlMaghrizat
    WHEN email = 'Tech-dream@hotmail.com' THEN 92  -- AlManar
    
    -- Jeri Car Services
    WHEN email IN ('Mohammed.AlOssaimi@shaheen-alarabia.com', 'MW-80101-JCS@joil.com.sa') THEN 51  -- Al-Munsiyah
    
    -- Limar El-Shams
    WHEN email = 'Mohamad.hamdan@limarcenter.com' THEN 87
    
    -- Motor Lube
    WHEN email = 'mohammed.kl@taajeer.com' THEN 63  -- Sultan Bin Salman
    
    -- Petromin - Body & Paint (already correctly mapped)
    WHEN email IN ('abdullah.nadeem@petromin.com', 'm.alnasser@petromin.com') THEN 47  -- Branch 604.
    WHEN email = 'amer.aljabari@petromin.com' THEN 45  -- Asfan
    WHEN email = 'faisal.akram@petromin.com' THEN 46  -- Al Nakheel
    WHEN email = 'wael.saeed@petromin.com' THEN 44  -- Exit 17.
    WHEN email = 'khalid.babiker@petromin.com' THEN 43  -- Exit 18.
    WHEN email = 'bilal.sheikh@petromin.com' THEN NULL  -- Qassim 359. not found
    
    -- Petromin East
    WHEN email IN ('mina.malak@petromin.com', 'ali.akbar@petromin.com', 'jeffrey.d@petromin.com') THEN 25  -- Jalawia/DAMMAM
    WHEN email = 'A.abueidhah@petromin.com' THEN 23  -- Rashid mall/KHOBAR
    WHEN email IN ('m.alkasslab@petromin.com', 'atif.awan@petromin.com', 'majid.bashir@petromin.com') THEN 24  -- Rayan/DAMMAM
    
    -- Petromin Riyadh
    WHEN email IN ('ahmed.othman@petromin.com', 'jaifer.ali@petromin.com') THEN 12  -- Al Duwadimi
    WHEN email = 'a.elbedaly@petromin.com' THEN 10  -- Alkahrj
    WHEN email IN ('nawab.zada@petromin.com', 's.syagha@petromin.com', 'm.abdulwaheed@petromin.com') THEN 4  -- Al-Malaz
    WHEN email IN ('Loay.abbas@Petromin.com', 'Jay.galapon@petromin.com') THEN 9  -- Al Narjis
    WHEN email = 'atawfik@petromin.com' THEN 13  -- AlQassim
    WHEN email = 'm.bata@petromin.com' THEN NULL  -- AlQassim Buraidah not found
    WHEN email = 'peerkhantaukeerraza@gmail.com' THEN 3  -- Azizia
    WHEN email IN ('j.meeran@petromin.com', 'Eyad.fahad@petromin.com', 'Mohammed.zahid@petromin.com') THEN 7  -- Badiya
    WHEN email = 'PAC-Darb@petromin.com' THEN NULL  -- Darb not found
    WHEN email IN ('s.alromaih@petromin.com', 'arman.iqbal@petromin.com', 'Kalander.mafaz@petromin.com') THEN 6  -- Exit 13.
    WHEN email IN ('mirza.kashan@petromin.com', 'zahid.asghar@petromin.com', 'immam.alam@petromin.com') THEN 8  -- Exit 14.
    WHEN email IN ('mahmoud.z@petromin.com', 'Wael.ali@petromin.com', 'mchengaruth@petromin.com', 'm.hindi@petromin.com') THEN 5  -- Khurais
    WHEN email IN ('Aminah.alotaibi@petromin.com', 'Mahmoud.goudah@petromin.com', 'Joud.fakoush@petromin.com', 'Majed.sayed@petromin.com') THEN 1  -- Masif
    WHEN email IN ('M.raoofuddin@petromin.com', 'Ahmed.sayed@petromin.com', 'h.alrahil@petromin.com', 'Malik.azhar@petromin.com') THEN 2  -- Thumama
    
    -- Petromin West
    WHEN email IN ('o.ghonem@petromin.com', 'pac-aboor@petromin.com') THEN 32  -- Aboor
    WHEN email IN ('Waleed.abdulghafoor@petromin.com', 'deepak.j@petromin.com', 'mohammed.halmi@petromin.com', 'junaid19655@gmail.com') THEN 14  -- AlAmal
    WHEN email IN ('zahidi.joiya@petromin.com', 'ahmed.mohamed@petromin.com', 'bassam.sakhnini@petromin.com') THEN 20  -- Al-DahamLand
    WHEN email = 'ferasmummar@gmail.com' THEN 35  -- AL Jabria Centre
    WHEN email IN ('adham.aldini@petromin.com', 'majed.khan@petromin.com', 'm.najah@petromin.com') THEN 19  -- Al Murabaland
    WHEN email IN ('shohidul.islam@petromin.com', 'm.aslam@petromin.com', 'Ahmed.jamali@petromin.com') THEN 22  -- Al-Safa Land
    WHEN email IN ('g.syed@petromin.com', 'arshad.k@petromin.com', 'mohammed.khaleel@petromin.com') THEN 18  -- Hamdaniya
    WHEN email IN ('mohammed.saad@petromin.com', 'imad.shahzad@petromin.com', 'f.batayb@petromin.com') THEN 21  -- Madinah Arbaeen.
    WHEN email = ' m.elafany@petromin.com' THEN 17  -- Nahada
    WHEN email IN ('hassan.tariq@petromin.com', 'abdulkareem.aliakbar@petromin.com') THEN 15  -- Rabea
    
    -- PIT STOP
    WHEN email = 'alaa@universalcar-sa.com' THEN 89
    
    -- Qparts (internal users - no branch needed)
    WHEN email IN ('qparts8@gmail.com', 'alaa.khedr196@gmail.com') THEN NULL
    
    -- Saptco branches
    WHEN email = 'alsaeefat@saptco.com.sa' THEN 73  -- Saptco - Aseer
    WHEN email = 'aldawoodas@saptco.com.sa' THEN 72  -- Saptco - Dammam
    WHEN email = 'Alsheikhmh@saptco.com.sa' THEN 74  -- Saptco - Jazan
    WHEN email = 'abdouof@saptco.com.sa' THEN 69  -- Saptco - Jeddah
    WHEN email = 'alsenanimn@saptco.com.sa' THEN 71  -- Saptco - Madina
    WHEN email = 'banayamanas@saptco.com.sa' THEN 70  -- Saptco - Makkah
    WHEN email = 'jamiasdp@saptco.com.sa' THEN 76  -- Saptco - Qassim
    WHEN email = 'ahmedaha@saptco.com.sa' THEN 68  -- Saptco - Riyadh
    WHEN email = 'aliua@saptco.com.sa' THEN 75  -- Saptco - Taif
    
    -- Tawuniya branches
    WHEN email IN ('k.alomiry@universalcar-sa.com', 'sales.body@universalcar-sa.com') THEN 67  -- Alalamiya
    WHEN email = 'dreams8cars@gmail.com' THEN 66  -- Dream
    WHEN email = 'nsamat2012@hotmail.com' THEN 65  -- Nasmat
    WHEN email = 'LAlshanqiti@tawuniya.com' THEN 64  -- Tawuniya
    
    -- Turbo Car Care
    WHEN email = 'Turbocare27@gmail.com' THEN 94
    
    ELSE NULL
END
WHERE user_branch IS NULL;;
