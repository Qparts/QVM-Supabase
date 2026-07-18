-- Create a helper table to complete branch mappings
-- This script provides the structure needed to map users to their correct branches

-- Create a temporary mapping reference
CREATE TABLE IF NOT EXISTS temp_branch_mapping_completion (
    email TEXT PRIMARY KEY,
    user_branch_name TEXT,
    customer_id INTEGER,
    company_name TEXT
);

-- Insert the actual mappings from main branch data
-- This would need to be populated with the actual data from users_main_data
-- For now, here's the structure:

/*
Sample data structure that should be inserted:
INSERT INTO temp_branch_mapping_completion (email, user_branch_name, customer_id, company_name) VALUES
('A.abueidhah@petromin.com', 'Rashid mall/KHOBAR', 1, 'Petromin East'),
('a.almarakshi@petromin.com', '-', NULL, 'Petromin'),
('abdelkarimam@saptco.com.sa', 'Saptco - Riyadh', NULL, 'Saptco'),
-- ... continue for all users
*/

-- Update query to apply branch mappings once data is available
/*
UPDATE qvm_new_apps.user_data
SET user_branch = tmc.customer_id
FROM temp_branch_mapping_completion tmc
WHERE qvm_new_apps.user_data.email = tmc.email;
*/

-- Show current completion status
SELECT
    'Migration Status' as status,
    COUNT(*) as total_users,
    COUNT(CASE WHEN user_company IS NOT NULL THEN 1 END) as companies_mapped,
    COUNT(CASE WHEN user_role IS NOT NULL THEN 1 END) as roles_mapped,
    COUNT(CASE WHEN user_branch IS NOT NULL THEN 1 END) as branches_mapped,
    COUNT(CASE WHEN user_type = 185 THEN 1 END) as qparts_team,
    COUNT(CASE WHEN user_type = 183 THEN 1 END) as clients
FROM qvm_new_apps.user_data;
