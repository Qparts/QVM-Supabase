-- Synced from QVM/test branch applied migration history (version 20260218160918, name: update_vendors_with_complete_data_chunk_10)
-- Update vendors 451-494 with complete data from main branch
UPDATE qvm_new_apps.vendors v
SET 
    zoho_name = CASE v.vendor_id
        WHEN 451 THEN NULL
        WHEN 452 THEN 'جي كلاس لزينة السيارات'
        WHEN 453 THEN 'شركة الاستراتيجي للتجارة'
        WHEN 454 THEN NULL
        WHEN 455 THEN 'مركز العالم لصيانة السيارات'
        WHEN 456 THEN 'ورشة الصفا كهربائي سيارات'
        WHEN 457 THEN 'مؤسسة احمد الفلاح للتجارة قطع غيار سيارات تويوتا'
        WHEN 458 THEN 'مؤسسة محمد سعيد العامودي للتجارة لبيع الرمان بلي'
        WHEN 459 THEN NULL
        WHEN 460 THEN NULL
        WHEN 461 THEN 'شركة عالم القوة للبطاريات'
        WHEN 462 THEN 'شركة المفيد لقطع الغيار'
        WHEN 463 THEN 'مؤسسة صدى المحرك التجارية'
        WHEN 464 THEN NULL
        WHEN 465 THEN 'مؤسسة المنصة الغربية للتجارة'
        WHEN 466 THEN 'مؤسسة البرغش التجارية'
        WHEN 467 THEN NULL
        WHEN 468 THEN 'مؤسسة السيار التجارية'
        WHEN 469 THEN NULL
        WHEN 470 THEN 'مؤسسة خليج القطع التجارية'
        WHEN 471 THEN NULL
        WHEN 472 THEN NULL
        WHEN 473 THEN NULL
        WHEN 474 THEN 'شركة التوريدات الوطنية للسيارات'
        WHEN 475 THEN NULL
        WHEN 476 THEN 'مؤسسة نجم المتحدة التجارية'
        WHEN 477 THEN NULL
        WHEN 478 THEN 'شركة انجاز الذهبية'
        WHEN 479 THEN 'شركة هادي المتميزة للتجارة'
        WHEN 480 THEN NULL
        WHEN 481 THEN 'شركة اجزاء العربة للتجارة'
        WHEN 482 THEN 'مؤسسة رواد المركزية لقطع غيار السيارات'
        WHEN 483 THEN NULL
        WHEN 484 THEN NULL
        WHEN 485 THEN 'مؤسسة الراية الذكية للتجارة'
        WHEN 486 THEN NULL
        WHEN 487 THEN NULL
        WHEN 488 THEN 'شركة العزم فولت للبطاريات'
        WHEN 489 THEN NULL
        WHEN 490 THEN NULL
        WHEN 491 THEN 'تشليح ابو يوسف'
        WHEN 492 THEN 'مؤسسة كون القطع لقطع غيار السيارات'
        WHEN 493 THEN NULL
        WHEN 494 THEN NULL
    END,
    vendor_type = CASE v.vendor_id
        WHEN 451 THEN 'وكيل'
        WHEN 452 THEN 'وكيل'
        WHEN 453 THEN 'وكيل'
        WHEN 454 THEN 'وكيل'
        WHEN 455 THEN 'وكيل'
        WHEN 456 THEN 'وكيل'
        WHEN 457 THEN 'وكيل'
        WHEN 458 THEN 'وكيل'
        WHEN 459 THEN 'وكيل'
        WHEN 460 THEN 'وكيل'
        WHEN 461 THEN 'وكيل'
        WHEN 462 THEN 'مورد'
        WHEN 463 THEN 'مورد'
        WHEN 464 THEN 'وكيل'
        WHEN 465 THEN 'مورد'
        WHEN 466 THEN 'مورد'
        WHEN 467 THEN 'وكيل'
        WHEN 468 THEN 'مورد'
        WHEN 469 THEN 'مورد'
        WHEN 470 THEN 'مورد'
        WHEN 471 THEN 'مورد'
        WHEN 472 THEN 'مورد'
        WHEN 473 THEN 'مورد'
        WHEN 474 THEN 'مورد'
        WHEN 475 THEN 'وكيل'
        WHEN 476 THEN 'مورد'
        WHEN 477 THEN 'مورد'
        WHEN 478 THEN 'مورد'
        WHEN 479 THEN 'مورد'
        WHEN 480 THEN 'مورد'
        WHEN 481 THEN 'مورد'
        WHEN 482 THEN 'مورد'
        WHEN 483 THEN 'مورد'
        WHEN 484 THEN 'مورد'
        WHEN 485 THEN 'مورد'
        WHEN 486 THEN 'مورد'
        WHEN 487 THEN 'وكيل'
        WHEN 488 THEN 'مورد'
        WHEN 489 THEN 'مورد'
        WHEN 490 THEN 'مورد'
        WHEN 491 THEN 'مورد'
        WHEN 492 THEN 'مورد'
        WHEN 493 THEN 'مورد'
        WHEN 494 THEN 'مورد'
    END,
    region = CASE v.vendor_id
        WHEN 451 THEN '["Riyadh"]'::jsonb
        WHEN 452 THEN '["Riyadh"]'::jsonb
        WHEN 453 THEN '["Riyadh"]'::jsonb
        WHEN 454 THEN '["Riyadh"]'::jsonb
        WHEN 455 THEN '["Riyadh"]'::jsonb
        WHEN 456 THEN '["Riyadh"]'::jsonb
        WHEN 457 THEN '["Riyadh"]'::jsonb
        WHEN 458 THEN '["Riyadh"]'::jsonb
        WHEN 459 THEN '["Riyadh"]'::jsonb
        WHEN 460 THEN '["Riyadh"]'::jsonb
        WHEN 461 THEN '["Riyadh"]'::jsonb
        WHEN 462 THEN '["East"]'::jsonb
        WHEN 463 THEN '["East"]'::jsonb
        WHEN 464 THEN '["West"]'::jsonb
        WHEN 465 THEN '["West"]'::jsonb
        WHEN 466 THEN '["East"]'::jsonb
        WHEN 467 THEN '["West"]'::jsonb
        WHEN 468 THEN '["East"]'::jsonb
        WHEN 469 THEN '["West"]'::jsonb
        WHEN 470 THEN '["East"]'::jsonb
        WHEN 471 THEN '["West"]'::jsonb
        WHEN 472 THEN '["West"]'::jsonb
        WHEN 473 THEN '["East"]'::jsonb
        WHEN 474 THEN '["Riyadh"]'::jsonb
        WHEN 475 THEN '["Riyadh"]'::jsonb
        WHEN 476 THEN '["East", " Riyadh"]'::jsonb
        WHEN 477 THEN '["East"]'::jsonb
        WHEN 478 THEN '["West"]'::jsonb
        WHEN 479 THEN '["West"]'::jsonb
        WHEN 480 THEN '["West"]'::jsonb
        WHEN 481 THEN '["West"]'::jsonb
        WHEN 482 THEN '["West"]'::jsonb
        WHEN 483 THEN '["West"]'::jsonb
        WHEN 484 THEN '["West"]'::jsonb
        WHEN 485 THEN '["West"]'::jsonb
        WHEN 486 THEN '["West"]'::jsonb
        WHEN 487 THEN '["Riyadh"]'::jsonb
        WHEN 488 THEN '["West"]'::jsonb
        WHEN 489 THEN '["West"]'::jsonb
        WHEN 490 THEN '["Riyadh"]'::jsonb
        WHEN 491 THEN '["West"]'::jsonb
        WHEN 492 THEN '["East"]'::jsonb
        WHEN 493 THEN '["East"]'::jsonb
        WHEN 494 THEN '["West"]'::jsonb
    END,
    operating_hours = CASE v.vendor_id
        WHEN 462 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5","العصر من 4 ل 8"]'::jsonb
        WHEN 463 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 464 THEN '["العصر من 4 ل 8"]'::jsonb
        WHEN 465 THEN '["العصر من 4 ل 8"]'::jsonb
        WHEN 466 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 467 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5"]'::jsonb
        WHEN 468 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 469 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8","المساء من 8 ل 10"]'::jsonb
        WHEN 470 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 471 THEN '["الصباح من 8 ل 12"]'::jsonb
        WHEN 472 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 473 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 474 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 475 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5"]'::jsonb
        WHEN 476 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5"]'::jsonb
        WHEN 477 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 478 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 479 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 480 THEN '["العصر من 4 ل 8","الصباح من 8 ل 12","المساء من 8 ل 10"]'::jsonb
        WHEN 481 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 482 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5","العصر من 4 ل 8"]'::jsonb
        WHEN 483 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5","العصر من 4 ل 8"]'::jsonb
        WHEN 484 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 485 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 486 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 487 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5"]'::jsonb
        WHEN 488 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8","المساء من 8 ل 10"]'::jsonb
        WHEN 489 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8"]'::jsonb
        WHEN 490 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5","العصر من 4 ل 8"]'::jsonb
        WHEN 491 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8","المساء من 8 ل 10"]'::jsonb
        WHEN 492 THEN '["العصر من 4 ل 8","الصباح من 8 ل 12"]'::jsonb
        WHEN 493 THEN '["الصباح من 8 ل 12","الظهر من 12 ل 5"]'::jsonb
        WHEN 494 THEN '["الصباح من 8 ل 12","العصر من 4 ل 8","المساء من 8 ل 10"]'::jsonb
    END,
    brands = CASE v.vendor_id
        WHEN 462 THEN '["MITSUBISHI","ISUZU"]'::jsonb
        WHEN 463 THEN '["Mazda","HYUNDAI","KIA"]'::jsonb
        WHEN 464 THEN '["MITSUBISHI"]'::jsonb
        WHEN 465 THEN '["PORSCHE","VOLKSWAGEN","AUDI"]'::jsonb
        WHEN 466 THEN '["GMC","FORD","CHEVROLET"]'::jsonb
        WHEN 467 THEN '["SUZUKI"]'::jsonb
        WHEN 468 THEN '["FORD","CHEVROLET"]'::jsonb
        WHEN 469 THEN '["CHERY","CHANGAN","GEELY","HAVAL"]'::jsonb
        WHEN 470 THEN '["MITSUBISHI","ISUZU"]'::jsonb
        WHEN 471 THEN '["BMW"]'::jsonb
        WHEN 472 THEN '["JMC"]'::jsonb
        WHEN 473 THEN '["Mazda","HYUNDAI","CHERY","MITSUBISHI","KIA","ISUZU","Nissan","TOYOTA"]'::jsonb
        WHEN 474 THEN '["JETOUR"]'::jsonb
        WHEN 475 THEN '["LUCID"]'::jsonb
        WHEN 476 THEN '["JEEP"]'::jsonb
        WHEN 478 THEN '["ACDELCO","CADILLAC","CHEVROLET","SUZUKI","KIA","HYUNDAI","HONDA","Mazda","FORD","GMC"]'::jsonb
        WHEN 479 THEN '["Nissan","SUZUKI","HONDA"]'::jsonb
        WHEN 481 THEN '["JEEP","DODGE","CHRYSLER"]'::jsonb
        WHEN 482 THEN '["Nissan"]'::jsonb
        WHEN 483 THEN '["Nissan"]'::jsonb
        WHEN 484 THEN '["Nissan"]'::jsonb
        WHEN 485 THEN '["CHANGAN"]'::jsonb
        WHEN 486 THEN '["HYUNDAI","KIA"]'::jsonb
        WHEN 487 THEN '["SSANGYONG"]'::jsonb
        WHEN 488 THEN '["TOYOTA"]'::jsonb
        WHEN 490 THEN '["ISUZU"]'::jsonb
        WHEN 491 THEN '["Nissan"]'::jsonb
        WHEN 492 THEN '["HYUNDAI","KIA"]'::jsonb
        WHEN 493 THEN '["CHEVROLET","MG"]'::jsonb
        WHEN 494 THEN '["Nissan"]'::jsonb
    END,
    items_type = CASE v.vendor_id
        WHEN 462 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 463 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 466 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 468 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 469 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 470 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 471 THEN '["Tires/Batteries"]'::jsonb
        WHEN 472 THEN '["Genuine"]'::jsonb
        WHEN 473 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 474 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 475 THEN '["Mech./Elec.","Body"]'::jsonb
        WHEN 476 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 477 THEN '["Aftermarket","Genuine"]'::jsonb
        WHEN 478 THEN '["Mech./Elec.","Genuine"]'::jsonb
        WHEN 479 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 480 THEN '["Tires/Batteries"]'::jsonb
        WHEN 481 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 482 THEN '["Aftermarket"]'::jsonb
        WHEN 483 THEN '["Aftermarket"]'::jsonb
        WHEN 484 THEN '["Mech./Elec.","Body","Genuine","Aftermarket"]'::jsonb
        WHEN 485 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 486 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 487 THEN '["Mech./Elec.","Body","Accessories","Genuine"]'::jsonb
        WHEN 488 THEN '["Tires/Batteries"]'::jsonb
        WHEN 489 THEN '["Aftermarket","Genuine"]'::jsonb
        WHEN 490 THEN '["Mech./Elec.","Accessories","Genuine","Aftermarket"]'::jsonb
        WHEN 491 THEN '["Mech./Elec.","Body"]'::jsonb
        WHEN 492 THEN '["Mech./Elec.","Genuine","Aftermarket"]'::jsonb
        WHEN 493 THEN '["Aftermarket","Genuine"]'::jsonb
        WHEN 494 THEN '["Mech./Elec."]'::jsonb
    END,
    payment_method = '122'
WHERE v.vendor_id BETWEEN 451 AND 494;;
