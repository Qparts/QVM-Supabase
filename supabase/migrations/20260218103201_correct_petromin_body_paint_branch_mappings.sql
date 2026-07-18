-- Correct the Petromin - Body & Paint branch mappings using the actual petromin_body_paint column
-- This fixes the wrong mappings to use the proper Body & Paint customer IDs

UPDATE qvm_new_apps.user_data
SET user_branch = CASE
    -- Use actual petromin_body_paint customer IDs
    WHEN email IN ('abdullah.nadeem@petromin.com', 'm.alnasser@petromin.com') THEN 8  -- Branch 604.
    WHEN email = 'amer.aljabari@petromin.com' THEN 6  -- Asfan

    -- For branches that don't exist in petromin_body_paint column, set to NULL
    -- as they don't have corresponding customer IDs
    WHEN email IN ('bilal.sheikh@petromin.com', 'faisal.akram@petromin.com',
                   'khalid.babiker@petromin.com', 'wael.saeed@petromin.com') THEN NULL
END
WHERE user_company = 2;
