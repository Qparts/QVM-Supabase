-- Synced from QVM/test branch applied migration history (version 20260218155410, name: copy_vendors_chunk_48)
-- Copy next 10 vendors (IDs 471-480)
INSERT INTO qvm_new_apps.vendors (
    vendor_id,
    vendor_name,
    zoho_name,
    vendor_type,
    region,
    operating_hours,
    brands,
    items_type,
    payment_method,
    tax_number,
    commercial_registeration_number,
    bank_name,
    bank_account,
    alternative_account,
    bank_and_cr_files,  -- Set to NULL
    created_at,
    updated_at,
    zoho_id,
    location,
    discount_percent,
    user_id
)
OVERRIDING SYSTEM VALUE
VALUES
(471, 'شركة الرشيدى للزيوت والبطاريات', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(472, 'مؤسسة خالد عبد الله ال اسحاق الصيعري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(473, 'مون ستار', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(474, 'التوريدات الوطنية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(475, 'شركة لوسيد', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(476, 'مؤسسة نجم المتحدة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(477, 'رواد الزيوت', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(478, 'شركة انجاز الذهبية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(479, 'هادي المتميزة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(480, 'شركة يحي عبدالرحمن الحوثري التجارية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL);;
