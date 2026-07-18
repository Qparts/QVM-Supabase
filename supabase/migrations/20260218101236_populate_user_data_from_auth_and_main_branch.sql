-- Populate qvm_new_apps.user_data table by combining data from auth.users (test branch)
-- and public.users_main_data (main branch) with proper mappings

INSERT INTO qvm_new_apps.user_data (
    user_id,
    email,
    user_branch,
    user_company,
    user_role,
    user_type,
    user_name,
    created_at,
    updated_at
)
WITH
-- Get auth users from test branch
auth_users AS (
    SELECT id, email
    FROM auth.users
    WHERE email IS NOT NULL
),

-- Get user main data from main branch (accessing via foreign data wrapper or direct connection)
-- Since we can't directly access main branch from test branch, we'll need to handle this differently
-- For now, let's create the structure and populate with what we can from auth users

-- Map user_type: Qparts Team = 185, Clients = 183
user_type_mapping AS (
    SELECT
        au.id as user_id,
        au.email,
        CASE
            WHEN au.email LIKE '%@qparts.co' THEN 185  -- Qparts Team
            ELSE 183  -- Clients
        END as user_type
    FROM auth_users au
)

-- Insert data with mappings that we can determine from email patterns
SELECT
    utm.user_id,
    utm.email,
    NULL::integer as user_branch,  -- Will need to be updated based on branch mapping
    NULL::integer as user_company, -- Will need to be updated based on company mapping
    NULL::integer as user_role,    -- Will need to be updated based on role mapping
    utm.user_type,
    SPLIT_PART(utm.email, '@', 1) as user_name, -- Extract name from email as placeholder
    NOW() AT TIME ZONE 'Asia/Riyadh' as created_at,
    NOW() AT TIME ZONE 'Asia/Riyadh' as updated_at
FROM user_type_mapping utm;
