-- Synced from QVM/test branch applied migration history (version 20260218155455, name: copy_vendors_chunk_50)
-- Copy final vendors (IDs 491-494)
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
(491, 'تشليح ابويوسف', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(492, 'كون القطع', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(493, 'مؤسسة اركان مشعل لقطع غيار السيارات', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL),
(494, 'مركز نوري المدينة لصيانة السيارات', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, '2025-06-16 08:02:28.73014+00', '2025-06-16 08:02:28.73014+00', NULL, NULL, NULL, NULL);;
