-- Synced from QVM/test branch applied migration history (version 20260218160531, name: update_vendors_with_complete_data_chunk_8)
-- Update vendors 351-400 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 351 THEN 'شركة سالم عبود بن عفيف للتجارة'
        WHEN 352 THEN NULL
        WHEN 353 THEN NULL
        WHEN 354 THEN NULL
        WHEN 355 THEN NULL
        WHEN 356 THEN 'شركة الشامل النموذجي لبيع قطع غيار السيارات ذ.م.م لبيع قطع غيار السيارات'
        WHEN 357 THEN NULL
        WHEN 358 THEN 'تكامل جدة'
        WHEN 359 THEN 'مؤسسة تاج الريان لقطع غيار السيارات الامريكية'
        WHEN 360 THEN NULL
        WHEN 361 THEN 'مؤسسة سعد عبدالله الزهراتي للتجارة'
        WHEN 362 THEN NULL
        WHEN 363 THEN 'مؤسسة باحميد لبيع قطع غيار السيارات'
        WHEN 364 THEN NULL
        WHEN 365 THEN 'شركة الاختيار الافضل لبيع و استيراد قطع غيار السيارات'
        WHEN 366 THEN NULL
        WHEN 367 THEN 'شركة الصياد المتطورة للتجارية مركز الاوائل لبيع جميع انواع البطاريات'
        WHEN 368 THEN NULL
        WHEN 369 THEN 'شركة العمودي للتجارة'
        WHEN 370 THEN NULL
        WHEN 371 THEN NULL
        WHEN 372 THEN NULL
        WHEN 373 THEN NULL
        WHEN 374 THEN 'شركة بن شيهون التجارية لقطع غيار السيارات'
        WHEN 375 THEN NULL
        WHEN 376 THEN NULL
        WHEN 377 THEN NULL
        WHEN 378 THEN NULL
        WHEN 379 THEN NULL
        WHEN 380 THEN 'شركة الشامل النموذجي لبيع قطع غيار السيارات ذ.م.م لبيع قطع غيار السيارات'
        WHEN 381 THEN NULL
        WHEN 382 THEN NULL
        WHEN 383 THEN 'شركة بركة المتحدون التجارية لقطع غيار السيارات'
        WHEN 384 THEN 'مؤسسة الوفاق المميزة لقطع غيار السيارات'
        WHEN 385 THEN 'شركة قطع المنارات لبيع قطع غيار السيارات جملة و قطاعي'
        WHEN 386 THEN 'مؤسسة المخزن الصيني للتجارة لقطع غيار السيارات الصينية'
        WHEN 387 THEN 'شركة صادق محمد حمزة خليفة و شركاه لبيع قطع غيار السيارات الامريكية'
        WHEN 388 THEN NULL
        WHEN 389 THEN 'شركة الفين لبيع قطع غيار السيارات'
        WHEN 390 THEN 'مؤسسة مجاهد عمر بابكير لبيع قطع غيار السيارات'
        WHEN 391 THEN 'شركة التاج اليافعي التجارية'
        WHEN 392 THEN 'مؤسسة هاني غزاي عواد المطيري لقطع غيار السيارات'
        WHEN 393 THEN 'مؤسسة الحزم التجارية لقطع غيار السيارات'
        WHEN 394 THEN 'عهد الاصدقاء لقطع غيار السيارات'
        WHEN 395 THEN 'مؤسسة الهضبة للتنمية التجارية'
        WHEN 396 THEN NULL
        WHEN 397 THEN 'مؤسسة رمز الصفوة'
        WHEN 398 THEN 'شركة اياد عبدالكريم ثابت التجارية'
        WHEN 399 THEN 'شركة أصل الشرق لقطع غيار السيارات الكورية و الصينية'
        WHEN 400 THEN 'شركة المرايا الدولية للتجارة'
    END,
    vendor_type = 'مورد',
    region = '["West"]'::jsonb,
    payment_method = '122'
WHERE v.vendor_id BETWEEN 351 AND 400;;
