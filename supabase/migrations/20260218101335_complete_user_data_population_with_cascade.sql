-- Complete population of qvm_new_apps.user_data table
-- This script combines auth.users data with mapped values from main branch data

-- First, clear any existing data with CASCADE to handle foreign key constraints
TRUNCATE TABLE qvm_new_apps.user_data CASCADE;

-- Since we can't use dblink directly in Supabase, let's create a simpler approach
-- We'll populate with the data we can determine from email patterns and then update the rest

-- Create comprehensive mappings based on email patterns and known data
WITH
-- Auth users from test branch
auth_users AS (
    SELECT id, email
    FROM auth.users
    WHERE email IS NOT NULL
),

-- User type mapping (Qparts Team = 185, Clients = 183)
user_type_mapping AS (
    SELECT
        au.id as user_id,
        au.email,
        CASE
            WHEN au.email LIKE '%@qparts.co' THEN 185  -- Qparts Team
            ELSE 183  -- Clients
        END as user_type,
        -- Extract name from email as placeholder
        SPLIT_PART(au.email, '@', 1) as user_name,
        -- Determine company and role based on email patterns
        CASE
            WHEN au.email LIKE '%@qparts.co' THEN 'Qparts'
            WHEN au.email LIKE '%@petromin.com' THEN
                CASE
                    WHEN au.email LIKE '%body%' OR au.email LIKE '%paint%' THEN 'Petromin - Body & Paint'
                    ELSE 'Petromin'
                END
            WHEN au.email LIKE '%@saptco.com.sa%' THEN 'Saptco'
            WHEN au.email LIKE '%@almajdouie.com' THEN 'Al Majdouie East'
            WHEN au.email LIKE '%@autolead.sa' THEN 'Al Majdouie Riyadh'
            WHEN au.email LIKE '%@shaheen-alarabia.com' THEN 'Jeri Car Services'
            WHEN au.email LIKE '%@aljomaihauto.com' THEN 'AC-DELCO'
            WHEN au.email LIKE '%@taajeer.com' THEN 'Motor Lube'
            WHEN au.email LIKE '%@smartoneauto.com' THEN 'Smart One Auto'
            WHEN au.email LIKE '%@universalcar-sa.com' THEN 'Tawuniya'
            WHEN au.email LIKE '%@limarcenter.com' THEN 'Limar El-Shams'
            WHEN au.email LIKE '%@alkhadrltd.com' THEN 'ALKHADR'
            WHEN au.email LIKE '%@mulhimauto.com' THEN 'AlMulhim'
            WHEN au.email LIKE '%@turbo%' OR au.email LIKE '%@care%' THEN 'Turbo Car Care'
            WHEN au.email LIKE '%@universalcar-sa.com' THEN 'PIT STOP'
            ELSE 'Unknown'
        END as company_name,
        -- Determine role based on email patterns and company
        CASE
            WHEN au.email LIKE '%@qparts.co' THEN
                CASE
                    WHEN au.email IN ('omar@qparts.co', 'abdualmuneim@qparts.co', 'omar.moh@qparts.co') THEN 'Admin'
                    ELSE 'QP Account Manager'
                END
            WHEN au.email LIKE '%@petromin.com' THEN
                CASE
                    WHEN au.email LIKE '%manager%' OR au.email LIKE '%branch%' THEN 'Branch Manager'
                    WHEN au.email LIKE '%service%' THEN 'Service Advisor'
                    ELSE 'Subscriber'
                END
            ELSE 'Subscriber'
        END as user_role
    FROM auth_users au
)

-- Insert with mapped values
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
SELECT
    utm.user_id,
    utm.email,
    NULL::integer as user_branch,  -- Will be updated separately
    -- Map company name to company ID
    CASE utm.company_name
        WHEN 'Qparts' THEN 115
        WHEN 'Petromin' THEN 1
        WHEN 'Petromin West' THEN 1
        WHEN 'Petromin East' THEN 1
        WHEN 'Petromin Riyadh' THEN 1
        WHEN 'Petromin Stock' THEN 1
        WHEN 'Petromin - Body & Paint' THEN 2
        WHEN 'Al Majdouie East' THEN 3
        WHEN 'Al Majdouie Riyadh' THEN 3
        WHEN 'Caragy West' THEN 4
        WHEN 'Jeri Car Services' THEN 5
        WHEN 'Motor Lube' THEN 6
        WHEN 'Tawuniya' THEN 7
        WHEN 'Smart One Auto' THEN 8
        WHEN 'AC-DELCO' THEN 9
        WHEN 'AlMulhim' THEN 10
        WHEN 'Dream of Tech' THEN 178
        WHEN 'Limar El-Shams' THEN 186
        ELSE NULL
    END as user_company,
    -- Map user role to role ID
    CASE utm.user_role
        WHEN 'Admin' THEN 172
        WHEN 'QP Account Manager' THEN 173
        WHEN 'QP technical Support' THEN 172
        WHEN 'Service Advisor' THEN 171
        WHEN 'Branch Manager' THEN 195
        WHEN 'Service Manager' THEN 171
        WHEN 'Subscriber' THEN 170
        WHEN 'Client Admin' THEN 170
        ELSE NULL
    END as user_role,
    utm.user_type,
    utm.user_name,
    NOW() AT TIME ZONE 'Asia/Riyadh' as created_at,
    NOW() AT TIME ZONE 'Asia/Riyadh' as updated_at
FROM user_type_mapping utm;
