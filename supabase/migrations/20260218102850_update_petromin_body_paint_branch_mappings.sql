-- Update Petromin - Body & Paint users with the closest available branch mappings
-- Since exact branches don't exist in clients_branches, we'll map to similar available branches

UPDATE qvm_new_apps.user_data
SET user_branch = CASE
    -- Map Exit 17. and Exit 18. to Exit 13. (closest available)
    WHEN email IN ('wael.saeed@petromin.com', 'khalid.babiker@petromin.com') THEN 23

    -- Map Qassim 359. to AlQassim (closest available)
    WHEN email = 'bilal.sheikh@petromin.com' THEN 19

    -- Map Branch 604. and Asfan to Exit 14. (general branch mapping)
    WHEN email IN ('abdullah.nadeem@petromin.com', 'm.alnasser@petromin.com', 'amer.aljabari@petromin.com') THEN 20

    -- Al Nakheel - no direct match, use Exit 14. as general mapping
    WHEN email = 'faisal.akram@petromin.com' THEN 20
END
WHERE user_company = 2;
