-- Complete missing company mappings using the new company IDs added to list_data

UPDATE qvm_new_apps.user_data
SET user_company = CASE
    -- Saptco users
    WHEN email LIKE '%@saptco.com.sa%' THEN 223  -- Saptco

    -- ALKHADR users
    WHEN email LIKE '%@alkhadrltd.com' THEN 227  -- ALKHADR

    -- Jeri Car Services users
    WHEN email LIKE '%@shaheen-alarabia.com' OR email LIKE '%@joil.com.sa' THEN 5  -- Jeri Car Services

    -- Tawuniya users
    WHEN email LIKE '%@universalcar-sa.com' OR email LIKE '%@tawuniya.com' OR email LIKE 'nsamat2012@hotmail.com' OR email LIKE 'lalshanqiti@tawuniya.com' OR email LIKE 'dreams8cars@gmail.com' THEN 7  -- Tawuniya

    -- Al Majdouie users
    WHEN email LIKE '%@almajdouie.com' OR email LIKE '%@autolead.sa' THEN 3  -- Al Majdouie

    -- AC-DELCO users
    WHEN email LIKE '%@aljomaihauto.com' THEN 9  -- ACDelco

    -- Motor Lube users
    WHEN email LIKE '%@taajeer.com' THEN 6  -- Motor Lube

    -- Smart One Auto users
    WHEN email LIKE '%@smartoneauto.com' THEN 8  -- Smart One Auto

    -- Limar El-Shams users
    WHEN email LIKE '%@limarcenter.com' THEN 186  -- Limar El-Shams

    -- AlMulhim users
    WHEN email LIKE '%@mulhimauto.com' THEN 229  -- AlMulhim

    -- Dream of Tech users
    WHEN email LIKE '%@hotmail.com' AND (email LIKE '%dream%' OR email LIKE '%tech%') THEN 225  -- Dream of Tech

    -- PIT STOP users
    WHEN email LIKE '%@universalcar-sa.com' AND email LIKE '%alaa%' THEN 228  -- PIT STOP (specifically alaa@universalcar-sa.com)

    -- Turbo Car Care users
    WHEN email LIKE '%@gmail.com' AND email LIKE '%turbo%' OR email LIKE '%care%' THEN 224  -- Turbo Car Care

    -- Carshub users
    WHEN email LIKE '%@carshub%' THEN 226  -- Carshub

    -- Alalamiya users
    WHEN email LIKE '%alalamiya%' THEN 177  -- Alalamiya

    -- Nasmat users
    WHEN email LIKE '%nasmat%' THEN 176  -- Nasmat

    -- Caragy users
    WHEN email LIKE '%caragy%' THEN 4  -- Caragy

    -- الملحم users
    WHEN email LIKE '%ملحم%' THEN 10  -- الملحم

    -- Default for any remaining Qparts users that weren't mapped
    WHEN email LIKE '%@qparts.co' THEN 115  -- Qparts

    ELSE NULL
END
WHERE user_company IS NULL;
