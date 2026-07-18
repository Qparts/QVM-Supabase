-- Synced from QVM/test branch applied migration history (version 20260218160028, name: update_vendors_with_complete_data_chunk_2)
-- Update vendors 51-100 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 51 THEN NULL
        WHEN 52 THEN NULL
        WHEN 53 THEN NULL
        WHEN 54 THEN 'شركة اوتو بانوراما لقطع غيار السيارات'
        WHEN 55 THEN 'شركة جودة الشرق الاوسط للتجارة'
        WHEN 56 THEN 'مؤسسة مدارات للقطع للتجارة'
        WHEN 57 THEN 'شركة وصف الجزيرة للتجارة'
        WHEN 58 THEN 'شركة ميزان عبد الحكيم الخطيب لصيانة السيارات'
        WHEN 59 THEN 'شركة امبراطور الخليج التجارية'
        WHEN 60 THEN 'مؤسسة ينابيع البركة'
        WHEN 61 THEN NULL
        WHEN 62 THEN 'شركة الضحيان قطع غيار السيارات'
        WHEN 63 THEN 'شركة ضياء البشائر للتجارة'
        WHEN 64 THEN 'مؤسسة احمد سالم باوزير التجارية'
        WHEN 65 THEN 'شركة الفلك الابيض المحدودة'
        WHEN 66 THEN 'باحشوان بارت'
        WHEN 67 THEN 'مؤسسة محمد احمد الغامدي التجارية'
        WHEN 68 THEN 'شركة محيط القطع'
        WHEN 69 THEN NULL
        WHEN 70 THEN 'شركة نجم الرمال'
        WHEN 71 THEN 'بالبيد لقطع الغيار'
        WHEN 72 THEN 'مؤسسة عالم المدارات'
        WHEN 73 THEN 'شركة توزيع وتسويق السيارات المحدودة'
        WHEN 74 THEN 'شركة باجحزر التجارية لقطع غيار السيارات'
        WHEN 75 THEN NULL
        WHEN 76 THEN 'مؤسسة دريم التعاون لقطع الغيار'
        WHEN 77 THEN 'مؤسسة اوتو زون بلس لقطع غيار السيارات'
        WHEN 78 THEN 'شركة عزم الموتر للتجارة موزع نعتمد لقطع غيار موبار الاصلية'
        WHEN 79 THEN 'مؤسسة دوج ستار لقطع غيار السيارات'
        WHEN 80 THEN NULL
        WHEN 81 THEN 'شركة روائع القطع التجارية'
        WHEN 82 THEN 'مؤسسة قطع و اكثر للتجارة'
        WHEN 83 THEN 'شركة منيف الأولى التجارية'
        WHEN 84 THEN 'شركة سور التكنولوجيا التجارية'
        WHEN 85 THEN 'مؤسسة فرسان الخليج لقطع غيار السيارات'
        WHEN 86 THEN NULL
        WHEN 87 THEN NULL
        WHEN 88 THEN 'العزم-موزع معتمد مبيعات قطع غيار'
        WHEN 89 THEN NULL
        WHEN 90 THEN 'شركة العزم الملهم'
        WHEN 91 THEN 'مؤسسة نوادر العمل للتجارة'
        WHEN 92 THEN 'شركة الخليفي للتجارة'
        WHEN 93 THEN 'شركة بشاير علي الصيعري'
        WHEN 94 THEN 'شركة محمد عمر بانعيم للتجارة'
        WHEN 95 THEN 'شركة العبدالله لقطع غيار السيارات فورد اصلية'
        WHEN 96 THEN 'مؤسسة محمد سعد محمد العقيد'
        WHEN 97 THEN 'شركة العملاق'
        WHEN 98 THEN 'واجهة شبيب'
        WHEN 99 THEN 'شركة خط القطع للتجارة'
        WHEN 100 THEN 'شركة تاج القوة للتجارة'
    END,
    vendor_type = 'مورد',
    region = '["Riyadh"]',
    payment_method = '122'
WHERE v.vendor_id BETWEEN 51 AND 100;;
