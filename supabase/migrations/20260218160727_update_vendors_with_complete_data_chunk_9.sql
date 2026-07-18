-- Synced from QVM/test branch applied migration history (version 20260218160727, name: update_vendors_with_complete_data_chunk_9)
-- Update vendors 401-450 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 401 THEN 'مؤسسة عبير محمد لقطع غيار السيارات'
        WHEN 402 THEN 'شركة وادي أحد لقطع غيار السيارات'
        WHEN 403 THEN 'شركة الزغيبي للتجارة'
        WHEN 404 THEN 'كشك الرواد للبطاريات'
        WHEN 405 THEN NULL
        WHEN 406 THEN 'اطلس الجنوب لقطع غيار السيارات'
        WHEN 407 THEN 'مؤسسة طريق المركبة التجارية'
        WHEN 408 THEN 'مؤسسة سيحان عيظه الزهراني - أيادي المتحدة'
        WHEN 409 THEN 'شركة بامسق لقطع غيار السيارات'
        WHEN 410 THEN 'شركة ازدان التميز للتجارة لقطع غيار السيارات'
        WHEN 411 THEN 'مؤسسة الحزم التجارية لقطع غيار السيارات'
        WHEN 412 THEN 'مؤسسة معروف لقطع غيار السيارات'
        WHEN 413 THEN NULL
        WHEN 414 THEN 'مؤسسة عبد المحسن المارق التجارية لبيع قطع غيار السيارات'
        WHEN 415 THEN NULL
        WHEN 416 THEN NULL
        WHEN 417 THEN 'شرارة'
        WHEN 418 THEN NULL
        WHEN 419 THEN NULL
        WHEN 420 THEN NULL
        WHEN 421 THEN 'شركة عبداللطيف جميل لبيع السيارات بالجملة'
        WHEN 422 THEN 'بترومين'
        WHEN 423 THEN 'شركة الجبر للتجارة'
        WHEN 424 THEN 'شركة محمد يوسف ناغي للسيارات'
        WHEN 425 THEN 'شركة الجميح للسيارات'
        WHEN 426 THEN 'شركة الوعلان للتجارة'
        WHEN 427 THEN 'تاجير لخدمات السيارات'
        WHEN 428 THEN 'شركة ابراهيم الجفالي واخوانه للسيارات'
        WHEN 429 THEN 'شركة مؤسسة العيسائي للتجارة'
        WHEN 430 THEN 'شركة المجدوعي للسيارات'
        WHEN 431 THEN 'شركة الحاج حسين علي رضا و شركاه المحدودة'
        WHEN 432 THEN 'العيسى العالمية للسيارات'
        WHEN 433 THEN NULL
        WHEN 434 THEN NULL
        WHEN 435 THEN NULL
        WHEN 436 THEN NULL
        WHEN 437 THEN NULL
        WHEN 438 THEN NULL
        WHEN 439 THEN NULL
        WHEN 440 THEN NULL
        WHEN 441 THEN NULL
        WHEN 442 THEN NULL
        WHEN 443 THEN NULL
        WHEN 444 THEN 'شركة جياد الحديثة للسيارات'
        WHEN 445 THEN 'شركة وهج الرواد للتجارة'
        WHEN 446 THEN NULL
        WHEN 447 THEN 'مؤسسة عبدالله رسلان العنزي لقطع غيار سيارات نيسان الاصلية و اليابانية'
        WHEN 448 THEN 'مؤسسة البرق اللامع للتجارة'
        WHEN 449 THEN NULL
        WHEN 450 THEN NULL
    END,
    vendor_type = CASE v.vendor_id
        WHEN 421 THEN 'وكيل'
        WHEN 422 THEN 'وكيل'
        WHEN 423 THEN 'وكيل'
        WHEN 424 THEN 'وكيل'
        WHEN 425 THEN 'وكيل'
        WHEN 426 THEN 'وكيل'
        WHEN 427 THEN 'وكيل'
        WHEN 428 THEN 'وكيل'
        WHEN 429 THEN 'وكيل'
        WHEN 430 THEN 'وكيل'
        WHEN 431 THEN 'وكيل'
        WHEN 432 THEN 'وكيل'
        WHEN 433 THEN 'وكيل'
        WHEN 434 THEN 'وكيل'
        WHEN 435 THEN 'وكيل'
        WHEN 436 THEN 'وكيل'
        WHEN 437 THEN 'وكيل'
        WHEN 438 THEN 'وكيل'
        WHEN 439 THEN 'وكيل'
        WHEN 440 THEN 'وكيل'
        WHEN 441 THEN 'وكيل'
        WHEN 442 THEN 'وكيل'
        WHEN 443 THEN 'وكيل'
        WHEN 444 THEN 'وكيل'
        WHEN 445 THEN 'وكيل'
        WHEN 446 THEN 'وكيل'
        WHEN 447 THEN 'وكيل'
        WHEN 448 THEN 'وكيل'
        WHEN 449 THEN 'وكيل'
        WHEN 450 THEN 'وكيل'
        ELSE 'مورد'
    END,
    region = CASE v.vendor_id
        WHEN 412 THEN '["East"]'::jsonb
        WHEN 413 THEN '["East"]'::jsonb
        WHEN 414 THEN '["East"]'::jsonb
        WHEN 415 THEN '["East"]'::jsonb
        WHEN 416 THEN '["East"]'::jsonb
        WHEN 417 THEN '["East"]'::jsonb
        WHEN 418 THEN '["East"]'::jsonb
        WHEN 419 THEN '["East"]'::jsonb
        WHEN 420 THEN '["East"]'::jsonb
        WHEN 421 THEN '["Riyadh"]'::jsonb
        WHEN 422 THEN '["Riyadh"]'::jsonb
        WHEN 423 THEN '["Riyadh"]'::jsonb
        WHEN 424 THEN '["Riyadh"]'::jsonb
        WHEN 425 THEN '["Riyadh"]'::jsonb
        WHEN 426 THEN '["Riyadh"]'::jsonb
        WHEN 427 THEN '["Riyadh"]'::jsonb
        WHEN 428 THEN '["Riyadh"]'::jsonb
        WHEN 429 THEN '["Riyadh"]'::jsonb
        WHEN 430 THEN '["Riyadh"]'::jsonb
        WHEN 431 THEN '["Riyadh"]'::jsonb
        WHEN 432 THEN '["Riyadh"]'::jsonb
        WHEN 433 THEN '["Riyadh"]'::jsonb
        WHEN 434 THEN '["Riyadh"]'::jsonb
        WHEN 435 THEN '["Riyadh"]'::jsonb
        WHEN 436 THEN '["Riyadh"]'::jsonb
        WHEN 437 THEN '["Riyadh"]'::jsonb
        WHEN 438 THEN '["Riyadh"]'::jsonb
        WHEN 439 THEN '["Riyadh"]'::jsonb
        WHEN 440 THEN '["Riyadh"]'::jsonb
        WHEN 441 THEN '["Riyadh"]'::jsonb
        WHEN 442 THEN '["Riyadh"]'::jsonb
        WHEN 443 THEN '["Riyadh"]'::jsonb
        WHEN 444 THEN '["Riyadh"]'::jsonb
        WHEN 445 THEN '["Riyadh"]'::jsonb
        WHEN 446 THEN '["Riyadh"]'::jsonb
        WHEN 447 THEN '["Riyadh"]'::jsonb
        WHEN 448 THEN '["Riyadh"]'::jsonb
        WHEN 449 THEN '["Riyadh"]'::jsonb
        WHEN 450 THEN '["Riyadh"]'::jsonb
        ELSE '["West"]'::jsonb
    END,
    payment_method = '122'
WHERE v.vendor_id BETWEEN 401 AND 450;;
