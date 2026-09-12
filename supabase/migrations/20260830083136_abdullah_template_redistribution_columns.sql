-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- ① Agency price list — as the uploading vendor states it, per branch.
update qvm_new_apps.upload_templates set
  needs_vendor = true,
  needs_branch = true,
  allowed_for_vendor = true,
  blurb_ar = 'سعر الوكالة كما يذكره المورد الرافع — لكل فرع على حدة.',
  blurb_en = 'The agency price as stated by the uploading vendor — one file per branch.',
  note_ar = 'هذا ليس سعر الوكالة الرسمي، بل السعر كما يدّعيه المورد الرافع؛ ويُخزَّن باسمه وفرعه. '
            || 'وقاعدة ثلاثية السعر سارية: يكفي اثنان من (السعر · السعر بعد الخصم · نسبة الخصم).',
  note_en = 'This is not the official agency price — it is the price as the uploading vendor states '
            || 'it, stored under their name and branch. The price-triple rule applies: any two of '
            || '(price · price after discount · discount %) suffice.',
  screen_fields = jsonb_build_array(
    jsonb_build_object('ar','الطرف المصدر — المورد','en','Source party — the vendor'),
    jsonb_build_object('ar','الفرع (ملف لكل فرع — الفرع ليس عمودًا بالملف)','en','Branch (one file per branch — the branch is not a column)'),
    jsonb_build_object('ar','تاريخ السريان (للملف كله)','en','Effective date (for the whole file)'),
    jsonb_build_object('ar','تاريخ الانتهاء (اختياري)','en','Expiry date (optional)')),
  columns = jsonb_build_array(
    jsonb_build_object('key','part_number','label_en','part_number','label_ar','رقم القطعة','required',true,
                       'note_en','Raw','note_ar','كما هو — يُنظَّف آليًا'),
    jsonb_build_object('key','name_ar','label_en','name_ar','label_ar','الاسم بالعربية','required',false,
                       'note_en','Auto-filled when left blank','note_ar','يُكمَل تلقائيًا إن تُرك فارغًا'),
    jsonb_build_object('key','name_en','label_en','name_en','label_ar','الاسم بالإنجليزية','required',false,
                       'note_en','Optional','note_ar','اختياري'),
    jsonb_build_object('key','make','label_en','make','label_ar','الماركة','required',true,
                       'note_en','BRAND','note_ar','العلامة التجارية'),
    jsonb_build_object('key','part_class','label_en','part_class','label_ar','الصنف','required',true,
                       'note_en','Genuine / OEM / Commercial / Used','note_ar','أصلي / OEM / تجاري / مستعمل'),
    jsonb_build_object('key','agency_price','label_en','agency_price','label_ar','سعر الوكالة','required',true,
                       'note_en','As stated by the uploading vendor','note_ar','مصدره المورد الرافع'),
    jsonb_build_object('key','dealer_agency_discount_pct','label_en','dealer_agency_discount_pct','label_ar','نسبة خصم الوكيل','required',false,
                       'note_en','Percentage','note_ar','نسبة مئوية'),
    jsonb_build_object('key','agency_price_after_discount','label_en','agency_price_after_discount','label_ar','سعر الوكالة بعد الخصم','required',false,
                       'note_en','Before VAT, SAR','note_ar','قبل الضريبة، بالريال'))
where template_key = 'agency_price_list';

-- ② Stock on hand — what you hold and what you sell it for. The agency columns move out.
update qvm_new_apps.upload_templates set
  note_ar = 'أسعار الوكالة لم تعد تُرفع من هنا — لها قالب «قائمة أسعار الوكالة» الذي يحمل المورد والفرع.',
  note_en = 'Agency prices are no longer uploaded here — they have their own template, which carries the vendor and the branch.',
  columns = (select jsonb_agg(c order by ord)
               from jsonb_array_elements(columns) with ordinality as x(c, ord)
              where c->>'key' not in ('agency_price','agency_price_after_discount','dealer_agency_discount_pct'))
where template_key = 'stock_on_hand';

-- ③ Past purchases — the full price triple, and the part named the same way as everywhere else.
update qvm_new_apps.upload_templates set
  note_ar = 'سعر الجملة هو ما دُفع فعلاً قبل الضريبة. وقاعدة ثلاثية السعر سارية: يكفي اثنان من '
            || '(سعر الجملة · السعر قبل الخصم · سعر التجزئة). والمدينة تُشتق من فرع المورد، فلا تُكتب في الملف.',
  note_en = 'The wholesale price is what was actually paid, before VAT. The price-triple rule applies: '
            || 'any two of (wholesale · before-discount · retail) suffice. The city comes from the '
            || 'vendor branch, so it is not a column.',
  columns = jsonb_build_array(
    jsonb_build_object('key','part_number','label_en','part_number','label_ar','رقم القطعة','required',true,
                       'note_en','Raw','note_ar','كما هو — يُنظَّف آليًا'),
    jsonb_build_object('key','supplier_name','label_en','supplier_name','label_ar','اسم المورد','required',true),
    jsonb_build_object('key','name_ar','label_en','name_ar','label_ar','الاسم بالعربية','required',false,
                       'note_en','Auto-filled when left blank','note_ar','يُكمَل تلقائيًا إن تُرك فارغًا'),
    jsonb_build_object('key','name_en','label_en','name_en','label_ar','الاسم بالإنجليزية','required',false,
                       'note_en','Optional','note_ar','اختياري'),
    jsonb_build_object('key','make','label_en','make','label_ar','الماركة','required',true,
                       'note_en','BRAND','note_ar','العلامة التجارية'),
    jsonb_build_object('key','part_class','label_en','part_class','label_ar','الصنف','required',false,
                       'note_en','Genuine / OEM / Commercial / Used','note_ar','أصلي / OEM / تجاري / مستعمل'),
    jsonb_build_object('key','qty','label_en','qty','label_ar','الكمية','required',false),
    jsonb_build_object('key','purchase_date','label_en','purchase_date','label_ar','تاريخ الشراء','required',true,
                       'note_en','YYYY-MM-DD','note_ar','سنة-شهر-يوم'),
    jsonb_build_object('key','wholesale_price','label_en','wholesale_price','label_ar','سعر الجملة','required',true,
                       'note_en','Before VAT, SAR','note_ar','قبل الضريبة، بالريال'),
    jsonb_build_object('key','retail_price','label_en','retail_price','label_ar','سعر التجزئة','required',false,
                       'note_en','Before VAT, SAR','note_ar','قبل الضريبة، بالريال'),
    jsonb_build_object('key','before_discount_price','label_en','before_discount_price','label_ar','السعر قبل الخصم','required',false,
                       'note_en','Before VAT, SAR','note_ar','قبل الضريبة، بالريال'))
where template_key = 'past_purchases';
