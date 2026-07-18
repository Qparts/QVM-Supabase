-- Synced from QVM/test branch applied migration history (version 20260218154209, name: copy_vendors_chunk_21)
-- Copy next 10 vendors (IDs 201-210)
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
(201, 'دوك', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(202, 'الجواد الادهم', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(203, 'ام مشاعل الكثيري', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(204, 'كراج القطع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(205, 'الطموح الذكي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(206, 'الغفيلي', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(207, 'ابداع الشبكة التجارية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(208, 'جيرمن بارتس', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(209, 'غياركم', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(210, 'محسن مظفر الدولية', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL);;
