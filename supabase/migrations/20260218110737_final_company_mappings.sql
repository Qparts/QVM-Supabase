-- Update the remaining users with company mappings based on their email patterns

UPDATE qvm_new_apps.user_data
SET user_company = CASE
    -- alaa.khedr196@gmail.com - based on name pattern, likely Qparts related
    WHEN email = 'alaa.khedr196@gmail.com' THEN 115  -- Qparts

    -- ferasmummar@gmail.com - unclear, set to Qparts as default
    WHEN email = 'ferasmummar@gmail.com' THEN 115  -- Qparts

    -- junaid19655@gmail.com - likely Petromin related based on previous data
    WHEN email = 'junaid19655@gmail.com' THEN 1  -- Petromin Auto Care

    -- peerkhantaukeerraza@gmail.com - likely Petromin based on name pattern
    WHEN email = 'peerkhantaukeerraza@gmail.com' THEN 1  -- Petromin Auto Care

    -- qparts8@gmail.com - clearly Qparts related
    WHEN email = 'qparts8@gmail.com' THEN 115  -- Qparts

    -- workshop@gmail.com - likely Dream of Tech based on previous patterns
    WHEN email = 'workshop@gmail.com' THEN 225  -- Dream of Tech
END
WHERE user_company IS NULL;
