-- Synced from QVM/test branch applied migration history (version 20260218160000, name: update_vendors_with_complete_data_chunk_1)
-- Update vendors 1-50 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 1 THEN 'شركة آفاق الاصلية للتجارة'
        WHEN 2 THEN 'شركة اسطورة الشرق  التجارية مركز السرور لقطع غيار السيارات'
        WHEN 3 THEN 'شركة أصل البركة لقطع الغيار'
        WHEN 4 THEN 'شركة الإنتاج الأصلي للتجارة'
        WHEN 5 THEN 'شركة التاج الكوري للتجارة'
        WHEN 6 THEN 'مؤسسة بسام جاسم الحميدان التجارية'
        WHEN 7 THEN 'شركة القرناس الذهبي التجارية'
        WHEN 8 THEN NULL
        WHEN 9 THEN 'شركة القطع الأصلية للتجارة بيع قطع غيار'
        WHEN 10 THEN 'مؤسسة حسن محمد باشماخ للتجارة'
        WHEN 11 THEN 'شركة دلتا البطحاء للتجارة'
        WHEN 12 THEN 'شركة راشد محمد الحمد التجارية'
        WHEN 13 THEN 'شركة رمز الريان التجارية لقطع الغيار'
        WHEN 14 THEN 'شركة رهدان التجاري'
        WHEN 15 THEN 'شركة روائع نيسان للتجارة'
        WHEN 16 THEN 'شركة ابشروا التجارية'
        WHEN 17 THEN 'شركة الحكمة العربية لتجارة قطع غيار'
        WHEN 18 THEN NULL
        WHEN 19 THEN 'شركة امداد العاصمة للتجارة'
        WHEN 20 THEN 'شركة امدادات الرياض للتجارة'
        WHEN 21 THEN 'شركة اهداف القطع'
        WHEN 22 THEN 'شركة تسلا الخليج للتجارة'
        WHEN 23 THEN 'شركة عبدالله عمر العمودي للتجارة'
        WHEN 24 THEN 'شركة بامسق لقطع غيار السيارات'
        WHEN 25 THEN 'شركة قمة المدارات'
        WHEN 26 THEN 'شركة محمد بن نهار القحطاني'
        WHEN 27 THEN 'شركة يوسف ابراهيم العوض لتجارة قطع غيار السيارات'
        WHEN 28 THEN 'شركة صقر الجزيرة لقطع غيار السيارات'
        WHEN 29 THEN 'شركة صناع النهضة لقطع غيار السيارات'
        WHEN 30 THEN 'مؤسسة البديل الاصلي التجارية'
        WHEN 31 THEN 'مؤسسة البشاير لقطع غيار السيارات'
        WHEN 32 THEN 'شركة القطع الشاملة للتجارة'
        WHEN 33 THEN 'شركة المصدر الحديثة للتجارة'
        WHEN 34 THEN 'مؤسسة دارس'
        WHEN 35 THEN 'شركة شمس الأصناف للتجارة لبيع قطع غيار'
        WHEN 36 THEN 'الشهري لقطع غيار السيارات'
        WHEN 37 THEN 'مؤسسة عبد المحسن صالح بانعيم للتجارة'
        WHEN 38 THEN 'مؤسسة فوزي فيصل هويدي التجارية'
        WHEN 39 THEN 'مؤسسة أحمد علي العمودي التجاري'
        WHEN 40 THEN 'شركة عبود احمد بن ماضي للتجارة'
        WHEN 41 THEN 'التضامن - مؤسسة عمر سالم باوزير للتجارة'
        WHEN 42 THEN 'شركة الاقواس التجارية'
        WHEN 43 THEN 'شركة الجبال الشامخة للتجارة - العطاس'
        WHEN 44 THEN NULL
        WHEN 45 THEN 'شركة نوادر الرياض للتجارة'
        WHEN 46 THEN 'شركة القطع المختصة للتجارة'
        WHEN 47 THEN NULL
        WHEN 48 THEN 'مؤسسة نهارمبارك القحطاني للتجارة'
        WHEN 49 THEN NULL
        WHEN 50 THEN NULL
    END,
    vendor_type = 'مورد',
    region = '["Riyadh"]',
    payment_method = '122'
WHERE v.vendor_id BETWEEN 1 AND 50;;
