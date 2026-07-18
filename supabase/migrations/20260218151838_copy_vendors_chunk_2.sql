-- Synced from QVM/test branch applied migration history (version 20260218151838, name: copy_vendors_chunk_2)
-- Copy next 10 vendors (IDs 11-20)
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
(11, 'دلتا البطحاء', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(12, 'راشد الحمد التجارية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(13, 'رمز الريان', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(14, 'رهدان', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(15, 'روائع نيسان', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(16, 'شركة ابشرو للتجارة ياباني', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(17, 'شركة الحكمة العربية للتجارة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(18, 'مؤسسة دار الظبي للتجارة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(19, 'شركة امداد العاصمة للتجارة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(20, 'شركة امدادات الرياض', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL);;
