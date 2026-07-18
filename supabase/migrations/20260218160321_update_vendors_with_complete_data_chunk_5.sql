-- Synced from QVM/test branch applied migration history (version 20260218160321, name: update_vendors_with_complete_data_chunk_5)
-- Update vendors 201-250 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 201 THEN 'مؤسسة دوك لقطع غيار السيارات'
        WHEN 202 THEN 'شركة الجواد الادهم'
        WHEN 203 THEN 'شركة ام مشاعل الكثيري التجارية'
        WHEN 204 THEN NULL
        WHEN 205 THEN 'مؤسسة الطموح الذكي للتجارة'
        WHEN 206 THEN 'مؤسسة الغفيلي'
        WHEN 207 THEN 'مؤسسة ابداع الشبكة التجارية لخدمات السيارات'
        WHEN 208 THEN NULL
        WHEN 209 THEN 'مؤسسة غياركم لقطع غيار السيارات'
        WHEN 210 THEN 'مؤسسة محسن مظفرالدولية للتجارة'
        WHEN 211 THEN 'شركة فرج سالم النعمامي للتجارة'
        WHEN 212 THEN 'شركة فن الاعمال'
        WHEN 213 THEN 'شركة ريماز'
        WHEN 214 THEN 'شركة مدار القطع للتجارة'
        WHEN 215 THEN 'مؤسسة ناصر سليمان بن نعيمان'
        WHEN 216 THEN 'مؤسسة امداد الخدمات للتجارة لقطع غيار ميتسوبيشي اصلية'
        WHEN 217 THEN 'مستودع طه بيع قطع غيار مرسيدس'
        WHEN 218 THEN 'مؤسسة القوة الثلاثية التجارية'
        WHEN 219 THEN 'مركز جينرال لقطع الغيار'
        WHEN 220 THEN 'مؤسسة سمو المركبة للتجارة'
        WHEN 221 THEN 'شركة المهد لقطع غيار السيارات للتجارة لقطع غيار سيارات'
        WHEN 222 THEN 'مؤسسة بن معجب التجارية'
        WHEN 223 THEN 'الواحة لحلول البطاريات'
        WHEN 224 THEN 'شركة اجياد الحاصر للتجارة لبيع البطاريات(جملة مفرق)'
        WHEN 225 THEN 'الجزاع لقطع غيار السيارات'
        WHEN 226 THEN 'شركة مسار المحركات لقطع الغيار'
        WHEN 227 THEN 'قمة النظائر لقطع الغيار'
        WHEN 228 THEN 'الكسار لقطع غيار السيارات'
        WHEN 229 THEN 'محل سباكة الكهرباء و الصيانة لصاحبها /محمد سعيد الدوسري'
        WHEN 230 THEN 'مؤسسة العقيل لبيع قطع غيار السيارات'
        WHEN 231 THEN 'الوكالة لقطع غيار السيارات'
        WHEN 232 THEN 'مؤسسة عبدالله جمعان التجارية لبيع قطع غيار لكزس'
        WHEN 233 THEN 'ورشة صدى'
        WHEN 234 THEN 'مركز روابي المدا لصيانة السيارات'
        WHEN 235 THEN 'ورشة 109-12 للرديترات و الشكمانات والتبريد و التكييف'
        WHEN 236 THEN 'ورشة نسائم الغدير لصيانة السيارات'
        WHEN 237 THEN 'شركة ماجد سالم صالح عبد العزيز للتجارة تجارة الجملة و التجزئة للتكييف و التبريد'
        WHEN 238 THEN 'مخرطة'
        WHEN 239 THEN NULL
        WHEN 240 THEN NULL
        WHEN 241 THEN NULL
        WHEN 242 THEN 'تشليح الثوري لبيع قطع غيار السيارات المستعملة'
        WHEN 243 THEN 'مؤسسة العربة الفاخرة'
        WHEN 244 THEN NULL
        WHEN 245 THEN 'تشليح البورت لقطع غيار السيارات المستعملة'
        WHEN 246 THEN 'شركة الاربعين للتجارة'
        WHEN 247 THEN NULL
        WHEN 248 THEN 'شركة قطع الفارس لبيع قطع غيار السيارات'
        WHEN 249 THEN 'بسمة البشاير لقطع غيار السيارات'
        WHEN 250 THEN 'مركز سراج عمر بن سراج جمل لصيانة السيارات'
    END,
    vendor_type = 'مورد',
    region = '["Riyadh"]'::jsonb,
    payment_method = '122'
WHERE v.vendor_id BETWEEN 201 AND 250;;
