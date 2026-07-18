-- Update users with company_name "Petromin - Body & Paint" to have user_company = 2
-- These users were identified from the main branch users_main_data table

UPDATE qvm_new_apps.user_data
SET user_company = 2  -- Petromin - Body & Paint company ID
WHERE email IN (
    'abdullah.nadeem@petromin.com',
    'amer.aljabari@petromin.com',
    'bilal.sheikh@petromin.com',
    'faisal.akram@petromin.com',
    'khalid.babiker@petromin.com',
    'm.alnasser@petromin.com',
    'wael.saeed@petromin.com'
);
