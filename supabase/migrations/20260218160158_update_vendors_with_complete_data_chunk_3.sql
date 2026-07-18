-- Synced from QVM/test branch applied migration history (version 20260218160158, name: update_vendors_with_complete_data_chunk_3)
-- Update vendors 101-150 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 101 THEN 'مؤسسة ربوع نعمان للتجارة'
        WHEN 102 THEN NULL
        WHEN 103 THEN NULL
        WHEN 104 THEN 'مؤسسة رمز التمكين قطع غيار اصلية'
        WHEN 105 THEN 'مؤسسة مختص لقطع الغيار'
        WHEN 106 THEN 'شركة محمد علي التميمي للتجارة'
        WHEN 107 THEN 'مؤسسة التيار البارد للتجارة'
        WHEN 108 THEN 'مؤسسة مشعل عتيق محمد السرحان السبيعي لصيانة السيارت'
        WHEN 109 THEN NULL
        WHEN 110 THEN 'شركة متاجر الاصناف للتجارة'
        WHEN 111 THEN 'فرع الزهراني لادوات الزينة و الزيوت'
        WHEN 112 THEN NULL
        WHEN 113 THEN NULL
        WHEN 114 THEN 'شركة آفاق الاصلية للتجارة'
        WHEN 115 THEN 'شركة خط القطع للتجارة'
        WHEN 116 THEN 'مؤسسة احمد سعيد علي النهدي التجارية لبيع قطع غيار السيارات'
        WHEN 117 THEN NULL
        WHEN 118 THEN 'مؤسسة الجيل'
        WHEN 119 THEN 'شركة عالم اروبا'
        WHEN 120 THEN 'شركة المغلوث'
        WHEN 121 THEN 'شركة رواحل لقطع غيار السيارات الامريكية'
        WHEN 122 THEN 'مؤسسة محمد مسلم المهري التجارية'
        WHEN 123 THEN 'مؤسسة نجوم الشراع العربي التجارية'
        WHEN 124 THEN 'شركة الخط الاحمر لقطع لغيار'
        WHEN 125 THEN 'شركة ابو مازن لبيع قطع غيار السيارات'
        WHEN 126 THEN NULL
        WHEN 127 THEN NULL
        WHEN 128 THEN 'مؤسسة شباب الشرقية التجارية'
        WHEN 129 THEN 'مؤسسة عبدالله صالح حسين ناصر للتجارة'
        WHEN 130 THEN 'شركة سليمان احمد خميس النعماني للتجارة'
        WHEN 131 THEN NULL
        WHEN 132 THEN 'شركة الحسوة التجارية ذ.م.م لبيع قطع غيار السيارات'
        WHEN 133 THEN 'شركة وادي العز لقطع غيار السيارات'
        WHEN 134 THEN NULL
        WHEN 135 THEN 'مؤسسة الحل المثيل'
        WHEN 136 THEN 'شركة سعيد بن حيدرة التجارية'
        WHEN 137 THEN 'شركة عميد الزيوت لزيوت التشحيم -الدمام'
        WHEN 138 THEN 'مؤسسة نخبة الزيوت التجارية'
        WHEN 139 THEN NULL
        WHEN 140 THEN NULL
        WHEN 141 THEN 'عين التنين لقطع غيار السيارات الصينية'
        WHEN 142 THEN NULL
        WHEN 143 THEN 'شركة مصدر الزيوت للتجارة'
        WHEN 144 THEN NULL
        WHEN 145 THEN NULL
        WHEN 146 THEN 'همم التجارية'
        WHEN 147 THEN 'مستودع البلاد لبيع قطع غيار سيارات تويوتا و هيونداي الأصلية'
        WHEN 148 THEN NULL
        WHEN 149 THEN 'شركة بحر القطع لبيع قطع غيار هيونداي -كيا الاصلية'
        WHEN 150 THEN 'شركة زيوت الشرق التجارية'
    END,
    vendor_type = 'مورد',
    region = CASE v.vendor_id
        WHEN 118 THEN '["East"]'::jsonb
        WHEN 119 THEN '["East"]'::jsonb
        WHEN 120 THEN '["East"]'::jsonb
        WHEN 121 THEN '["East"]'::jsonb
        WHEN 122 THEN '["East"]'::jsonb
        WHEN 123 THEN '["East"]'::jsonb
        WHEN 124 THEN '["East"]'::jsonb
        WHEN 125 THEN '["East"]'::jsonb
        WHEN 126 THEN '["East"]'::jsonb
        WHEN 127 THEN '["East"]'::jsonb
        WHEN 128 THEN '["East"]'::jsonb
        WHEN 129 THEN '["East"]'::jsonb
        WHEN 130 THEN '["East"]'::jsonb
        WHEN 131 THEN '["East"]'::jsonb
        WHEN 132 THEN '["East"]'::jsonb
        WHEN 133 THEN '["East"]'::jsonb
        WHEN 134 THEN '["East"]'::jsonb
        WHEN 135 THEN '["East"]'::jsonb
        WHEN 136 THEN '["East"]'::jsonb
        WHEN 137 THEN '["East"]'::jsonb
        WHEN 138 THEN '["East"]'::jsonb
        WHEN 139 THEN '["East"]'::jsonb
        WHEN 140 THEN '["East"]'::jsonb
        WHEN 141 THEN '["East"]'::jsonb
        WHEN 142 THEN '["East"]'::jsonb
        WHEN 143 THEN '["East"]'::jsonb
        WHEN 144 THEN '["East"]'::jsonb
        WHEN 145 THEN '["East"]'::jsonb
        WHEN 146 THEN '["East"]'::jsonb
        WHEN 147 THEN '["East"]'::jsonb
        WHEN 148 THEN '["East"]'::jsonb
        WHEN 149 THEN '["East"]'::jsonb
        WHEN 150 THEN '["East"]'::jsonb
        ELSE '["Riyadh"]'::jsonb
    END,
    payment_method = '122'
WHERE v.vendor_id BETWEEN 101 AND 150;;
