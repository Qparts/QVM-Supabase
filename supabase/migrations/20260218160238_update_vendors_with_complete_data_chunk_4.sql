-- Synced from QVM/test branch applied migration history (version 20260218160238, name: update_vendors_with_complete_data_chunk_4)
-- Update vendors 151-200 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 151 THEN 'مؤسسة سعد فهاد الهاجري لقطع غيار السيارات'
        WHEN 152 THEN NULL
        WHEN 153 THEN NULL
        WHEN 154 THEN 'شركة المستودع العربي لقطع غيار السيارات'
        WHEN 155 THEN NULL
        WHEN 156 THEN 'شركة المواسم الاولى لقطع غيار السيارات'
        WHEN 157 THEN NULL
        WHEN 158 THEN 'شركة تسع و تسعين لقطع الغيار'
        WHEN 159 THEN 'شركة مركز عيسى العنزي لقطع الغيار'
        WHEN 160 THEN 'مؤسسة سلمان البريكي لقطع غيار السيارات هونداي-كيا الاصلية'
        WHEN 161 THEN NULL
        WHEN 162 THEN 'شركة وسام الطريق للتجارة لقطع غيار السيارات'
        WHEN 163 THEN NULL
        WHEN 164 THEN 'مؤسسة ناصر علي ال مبطي التجارية'
        WHEN 165 THEN 'مؤسسة شارة البداية التجارية قطع غيار'
        WHEN 166 THEN 'شركة نور القطع التجارية'
        WHEN 167 THEN 'شركة عبد الرحمن احمد عبدالله الرجحي التجارية'
        WHEN 168 THEN 'شركة نجم التقوى التجارية'
        WHEN 169 THEN 'شركة مجد الصفا التجارية قطع غيار السيارات'
        WHEN 170 THEN NULL
        WHEN 171 THEN NULL
        WHEN 172 THEN NULL
        WHEN 173 THEN 'مؤسسة درة اسيا لقطع الغيار'
        WHEN 174 THEN NULL
        WHEN 175 THEN NULL
        WHEN 176 THEN 'مؤسسة احمد الحليمي'
        WHEN 177 THEN NULL
        WHEN 178 THEN NULL
        WHEN 179 THEN 'مؤسسة عالم القطع التجارية'
        WHEN 180 THEN 'مؤسسة عظمة التجارية مركز الظهران لقطع غيار السيارات'
        WHEN 181 THEN NULL
        WHEN 182 THEN NULL
        WHEN 183 THEN 'مؤسسة الاختيار الامثل'
        WHEN 184 THEN NULL
        WHEN 185 THEN NULL
        WHEN 186 THEN 'مؤسسة برج القطع'
        WHEN 187 THEN 'شركة الرشيد للسيارات المحدودة'
        WHEN 188 THEN NULL
        WHEN 189 THEN NULL
        WHEN 190 THEN 'شركة سالم صالح الحارثي التجارية'
        WHEN 191 THEN 'مؤسسة النمر الفضي التجارية'
        WHEN 192 THEN 'شركة اطار المسافر الحديث للتجارة'
        WHEN 193 THEN 'الخليجية للسيارات'
        WHEN 194 THEN 'مؤسسة شعار المركبات للبطاريات'
        WHEN 195 THEN 'مركزالمراكب الذهبيه لااطارات السيارات'
        WHEN 196 THEN 'مؤسسة ركن الكثيري'
        WHEN 197 THEN 'تشليح قمة كايين لبيع قطع غيار السيارات المستعملة'
        WHEN 198 THEN 'مؤسسة جزيرة القطع للتجارة'
        WHEN 199 THEN 'مؤسسة حصة عبد العزيز السيف للتجارة'
        WHEN 200 THEN 'شركة رواد المجد استيراد و بيع قطع غيار السيارات'
    END,
    vendor_type = 'مورد',
    region = CASE v.vendor_id
        WHEN 151 THEN '["East"]'::jsonb
        WHEN 152 THEN '["East"]'::jsonb
        WHEN 153 THEN '["East"]'::jsonb
        WHEN 154 THEN '["East"]'::jsonb
        WHEN 155 THEN '["East"]'::jsonb
        WHEN 156 THEN '["East"]'::jsonb
        WHEN 157 THEN '["East"]'::jsonb
        WHEN 158 THEN '["East"]'::jsonb
        WHEN 159 THEN '["East"]'::jsonb
        WHEN 160 THEN '["East"]'::jsonb
        WHEN 161 THEN '["East"]'::jsonb
        WHEN 162 THEN '["East"]'::jsonb
        WHEN 163 THEN '["East"]'::jsonb
        WHEN 164 THEN '["East"]'::jsonb
        WHEN 165 THEN '["East"]'::jsonb
        WHEN 166 THEN '["East"]'::jsonb
        WHEN 167 THEN '["East"]'::jsonb
        WHEN 168 THEN '["East"]'::jsonb
        WHEN 169 THEN '["East"]'::jsonb
        WHEN 170 THEN '["East"]'::jsonb
        WHEN 171 THEN '["East"]'::jsonb
        WHEN 172 THEN '["East"]'::jsonb
        WHEN 173 THEN '["East"]'::jsonb
        WHEN 174 THEN '["East"]'::jsonb
        WHEN 175 THEN '["East"]'::jsonb
        WHEN 176 THEN '["East"]'::jsonb
        WHEN 177 THEN '["East"]'::jsonb
        WHEN 178 THEN '["East"]'::jsonb
        WHEN 179 THEN '["East"]'::jsonb
        WHEN 180 THEN '["East"]'::jsonb
        WHEN 181 THEN '["East"]'::jsonb
        WHEN 182 THEN '["East"]'::jsonb
        WHEN 183 THEN '["East"]'::jsonb
        WHEN 184 THEN '["East"]'::jsonb
        WHEN 185 THEN '["East"]'::jsonb
        WHEN 186 THEN '["East"]'::jsonb
        WHEN 187 THEN '["Riyadh"]'::jsonb
        WHEN 188 THEN '["Riyadh"]'::jsonb
        WHEN 189 THEN '["Riyadh"]'::jsonb
        WHEN 190 THEN '["Riyadh"]'::jsonb
        WHEN 191 THEN '["Riyadh"]'::jsonb
        WHEN 192 THEN '["Riyadh"]'::jsonb
        WHEN 193 THEN '["Riyadh"]'::jsonb
        WHEN 194 THEN '["Riyadh"]'::jsonb
        WHEN 195 THEN '["Riyadh"]'::jsonb
        WHEN 196 THEN '["Riyadh"]'::jsonb
        WHEN 197 THEN '["Riyadh"]'::jsonb
        WHEN 198 THEN '["Riyadh"]'::jsonb
        WHEN 199 THEN '["Riyadh"]'::jsonb
        WHEN 200 THEN '["Riyadh"]'::jsonb
    END,
    payment_method = '122'
WHERE v.vendor_id BETWEEN 151 AND 200;;
