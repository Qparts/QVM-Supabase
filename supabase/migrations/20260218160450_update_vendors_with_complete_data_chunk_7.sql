-- Synced from QVM/test branch applied migration history (version 20260218160450, name: update_vendors_with_complete_data_chunk_7)
-- Update vendors 301-350 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 301 THEN 'مؤسسة سالم عبدالله بانعيم'
        WHEN 302 THEN 'مؤسسة رسم القطع التجارية'
        WHEN 303 THEN NULL
        WHEN 304 THEN 'ورشة فارس'
        WHEN 305 THEN 'تشليح وردة الجبيل لبيع قطع غيار السيارات المستعملة'
        WHEN 306 THEN 'مؤسسة جميلة صالح بن مبارك الصيعري التجارية'
        WHEN 307 THEN 'مركز احمد المالكي لبيع و شراء قطع السيارات المستعملة'
        WHEN 308 THEN NULL
        WHEN 309 THEN 'مؤسسة بسمة البشائر لدهانات السيارات'
        WHEN 310 THEN NULL
        WHEN 311 THEN 'نقليات المملكة'
        WHEN 312 THEN NULL
        WHEN 313 THEN NULL
        WHEN 314 THEN NULL
        WHEN 315 THEN 'شركة رواسي التجارة للتجارة لبيع قطع غيار السيارات'
        WHEN 316 THEN NULL
        WHEN 317 THEN 'مؤسسة مسما للتجارة لبيع حميع انواع فلاتر السيارات'
        WHEN 318 THEN 'مؤسسة محمد ناصر محمد القعيد'
        WHEN 319 THEN 'مؤسسة واحة السعادة للتجارة قطع غيار السيارات'
        WHEN 320 THEN NULL
        WHEN 321 THEN 'شركة رواسي التجارة للتجارة لبيع قطع غيار السيارات'
        WHEN 322 THEN 'مؤسسة المحركات السريعة المتقدمة لقطع غيار السيارات'
        WHEN 323 THEN 'ركن قطع كوم'
        WHEN 324 THEN 'شركة التنين لقطع غيار السيارات'
        WHEN 325 THEN 'شركة اقطار و ارجاء للتجارة'
        WHEN 326 THEN 'شركة ابناء عبود احمد باعاصم المحدودة لبيع ادوات توضيب جميع انواع السيارات الاميركية'
        WHEN 327 THEN 'مؤسسة العلامة الأصلية للتجارة بيع قطع غيار السيارات'
        WHEN 328 THEN 'مؤسسة عثمان علي (العمودي لقطع الغيار الاميركية)'
        WHEN 329 THEN 'مؤسسة الوان العربة قطع غيار اصلية'
        WHEN 330 THEN 'شركة عاصفة الرمال'
        WHEN 331 THEN NULL
        WHEN 332 THEN 'مؤسسة علي محمد ال سعيدي للتجارة'
        WHEN 333 THEN 'مؤسسة سعيد سالم سلمان عسيري للتجارة لقطع غيار بي ام دبليو و لاند روفر'
        WHEN 334 THEN 'مؤسسة لؤلؤة الرمال لبيع قطع غيار السيارات'
        WHEN 335 THEN 'شركة دعم المركبات للتجارة لبيع قطع غيار السيارات (جملة-مفرق)'
        WHEN 336 THEN 'مؤسسة دار الرباط للتجارة لقطع غيار سيارات ايسوزو'
        WHEN 337 THEN 'شركة المجد المشرق للتجارة لقطع غيار السيارات'
        WHEN 338 THEN 'شركة توكيلات الجزيرة للسيارت'
        WHEN 339 THEN 'شركة امجاد الوفاء لقطع غيار السيارات ذ.م.م'
        WHEN 340 THEN NULL
        WHEN 341 THEN NULL
        WHEN 342 THEN NULL
        WHEN 343 THEN NULL
        WHEN 344 THEN 'شركة الدرع الاحمر (الاعتلاء الدولي) لقطع غيار السيارات الاصلية'
        WHEN 345 THEN 'الرؤية السابعة لقطع غيار مازدا'
        WHEN 346 THEN NULL
        WHEN 347 THEN NULL
        WHEN 348 THEN 'مؤسسة باحكيم التجارية لبيع قطع غيار السيارات'
        WHEN 349 THEN 'مؤسسة الحداء لقطع غيار السيارات'
        WHEN 350 THEN 'مؤسسة رباع المجد لقطع غيار السيارات'
    END,
    vendor_type = 'مورد',
    region = CASE v.vendor_id
        WHEN 320 THEN NULL
        WHEN 321 THEN NULL
        WHEN 322 THEN NULL
        WHEN 323 THEN NULL
        WHEN 324 THEN NULL
        WHEN 325 THEN NULL
        WHEN 326 THEN NULL
        WHEN 327 THEN NULL
        WHEN 328 THEN NULL
        WHEN 329 THEN NULL
        WHEN 330 THEN NULL
        WHEN 331 THEN NULL
        WHEN 332 THEN NULL
        WHEN 333 THEN NULL
        WHEN 334 THEN NULL
        WHEN 335 THEN '["Riyadh"]'::jsonb
        WHEN 336 THEN '["Riyadh"]'::jsonb
        WHEN 337 THEN '["West"]'::jsonb
        WHEN 338 THEN '["West"]'::jsonb
        WHEN 339 THEN '["West"]'::jsonb
        WHEN 340 THEN '["West"]'::jsonb
        WHEN 341 THEN '["West"]'::jsonb
        WHEN 342 THEN '["West"]'::jsonb
        WHEN 343 THEN '["West"]'::jsonb
        WHEN 344 THEN '["West"]'::jsonb
        WHEN 345 THEN '["West"]'::jsonb
        WHEN 346 THEN '["West"]'::jsonb
        WHEN 347 THEN '["West"]'::jsonb
        WHEN 348 THEN '["West"]'::jsonb
        WHEN 349 THEN '["West"]'::jsonb
        WHEN 350 THEN '["West"]'::jsonb
        ELSE '["Riyadh"]'::jsonb
    END,
    payment_method = CASE v.vendor_id
        WHEN 320 THEN NULL
        WHEN 321 THEN NULL
        WHEN 322 THEN NULL
        WHEN 323 THEN NULL
        WHEN 324 THEN NULL
        WHEN 325 THEN NULL
        WHEN 326 THEN NULL
        WHEN 327 THEN NULL
        WHEN 328 THEN NULL
        WHEN 329 THEN NULL
        WHEN 330 THEN NULL
        WHEN 331 THEN NULL
        WHEN 332 THEN NULL
        WHEN 333 THEN NULL
        WHEN 334 THEN NULL
        ELSE '122'
    END
WHERE v.vendor_id BETWEEN 301 AND 350;;
