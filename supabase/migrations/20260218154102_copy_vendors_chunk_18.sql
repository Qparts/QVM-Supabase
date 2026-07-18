-- Synced from QVM/test branch applied migration history (version 20260218154102, name: copy_vendors_chunk_18)
-- Copy next 10 vendors (IDs 171-180)
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
(171, 'الاختصار', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(172, 'هادي عميرة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(173, 'درة اسيا', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(174, 'مجموعة صلاح بن حيدرة التجارية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(175, 'سحابة الذهبية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(176, 'الحليمي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(177, 'ارض الموردة', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(178, 'النجم المثلث', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(179, 'عالم القطع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(180, 'مؤسسة عظمة التجارية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL);;
