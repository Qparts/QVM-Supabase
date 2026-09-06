-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The same template content production runs: how each one is described on the upload screen, plus
-- the columns that were added once every one of them had somewhere to land.

update qvm_new_apps.upload_templates set
  icon = '🏛',
  screen_fields = jsonb_build_array(
    jsonb_build_object('ar','الطرف المصدر — الوكالة','en','Source party — the agency'),
    jsonb_build_object('ar','تاريخ السريان (للملف كله)','en','Effective date (for the whole file)'),
    jsonb_build_object('ar','تاريخ الانتهاء (اختياري)','en','Expiry date (optional)')),
  note_ar = 'قاعدة ثلاثية السعر: يكفي اثنان من (السعر · السعر بعد الخصم · نسبة الخصم)؛ أي تناقض أكبر من ٠٫٥٪ يُفشل الصف مع ذكر السبب.',
  note_en = 'Price-triple rule: any two of (price · price after discount · discount %) suffice; an inconsistency above 0.5% fails the row and says why.',
  lands = 'agency_price_reference'
where template_key = 'agency_price_list';

update qvm_new_apps.upload_templates set
  icon = '📦',
  screen_fields = jsonb_build_array(
    jsonb_build_object('ar','الطرف المصدر — المورد','en','Source party — the vendor'),
    jsonb_build_object('ar','الفرع (ملف لكل فرع — الفرع ليس عمودًا بالملف)','en','Branch (one file per branch — the branch is not a column)')),
  note_ar = 'أعمدة أسعار الوكالة اختيارية وتُخزَّن بمصدر «المورد الرافع» (وكالة كما يدّعيها المورد) ولا تمسّ سعر الوكالة الرسمي أبدًا — تخدم عرض فرق ٪ عن الوكالة.',
  note_en = 'The agency-price columns are optional and stored under the uploading vendor as the source — an agency price as the vendor claims it. They never touch the official agency price; they only feed the % difference.',
  lands = 'inventory_stock'
where template_key = 'stock_on_hand';

update qvm_new_apps.upload_templates set
  icon = '🧾',
  screen_fields = jsonb_build_array(
    jsonb_build_object('ar','الطرف المصدر — المورد','en','Source party — the vendor')),
  sheets_ar = 'شيت ١ «المشتريات» يحمل الأعمدة أدناه، وعمود كود المورد فيه قائمة منسدلة مربوطة بشيت ٢. شيت ٢ «الموردون» يتولّد لحظة التنزيل من بيانات النظام الحية (الكود، اسم المورد، الفرع، المدينة).',
  sheets_en = 'Sheet 1 "Purchases" carries the columns below, and its supplier-code column is a dropdown bound to sheet 2. Sheet 2 "Suppliers" is generated at download time from live system data (code, vendor name, branch, city).',
  note_ar = 'الكود ثابت لا يتغير حتى لو تغيّر اسم المورد؛ والاستيراد يتحقق من حالة الفرع (كود لفرع موقوف ← تنبيه).',
  note_en = 'The code never changes, even when the vendor is renamed; the import checks the branch is still active (a code for a stopped branch raises a warning).',
  lands = 'part_purchase_history',
  -- part_purchase_history.brand exists and the publish writes it, but the sheet never asked for a
  -- make, so every purchase row landed with an unqualified part number.
  columns = (select jsonb_agg(c order by ord) from (
      select c, ord from jsonb_array_elements(columns) with ordinality as x(c, ord)
       where c->>'key' <> 'make'
      union all
      select jsonb_build_object('key','make','label_en','make','label_ar','الماركة','required',true,
               'note_en','BRAND','note_ar','بدونها الرقم غير فريد بالكتالوج'), 2.5) s)
where template_key = 'past_purchases';

update qvm_new_apps.upload_templates set
  icon = '🔗',
  screen_fields = jsonb_build_array(
    jsonb_build_object('ar','الطرف المصدر','en','Source party')),
  warn_ar = 'هذا القالب للأرقام المكافئة لنفس القطعة فقط — القطع البديلة المختلفة (تجاري بدل أصلي) لها قالب آخر.',
  warn_en = 'This template is for equivalent numbers of the same part only — genuinely different substitute parts (commercial instead of genuine) belong to another template.',
  note_ar = 'سلوك الاستيراد: (١) الرقم المكافئ غير موجود ← يُضاف تلقائيًا · (٢) رقم القطعة غير موجود ← يُنشأ ثم يُربط · (٣) الرقمان موجودان ككيانين مستقلين ← مقترح دمج يُراجَع ولا يُنفَّذ تلقائيًا.',
  note_en = 'Import behaviour: (1) the equivalent number is unknown → it is added automatically · (2) the part number is unknown → it is created, then linked · (3) both already exist as separate entities → a merge is proposed for review, never applied automatically.',
  lands = 'part_aliases'
where template_key = 'aliases';

update qvm_new_apps.upload_templates set
  icon = '🏷',
  screen_fields = jsonb_build_array(
    jsonb_build_object('ar','الطرف المصدر — المورد','en','Source party — the vendor'),
    jsonb_build_object('ar','بداية العرض (للملف كله)','en','Offer start (for the whole file)'),
    jsonb_build_object('ar','نهاية العرض (للملف كله)','en','Offer end (for the whole file)')),
  warn_ar = 'رقم القطعة وصنفها لازم يكونان معرَّفَين سابقًا في الكتالوج — أي صف لرقم غير موجود يفشل ولا يُنشئ قطعة جديدة.',
  warn_en = 'The part number and its class must already exist in the catalog — a row for an unknown number fails and does not create a new part.',
  note_ar = 'شرط العرض يُكتب برقمه من الحالات المعتمدة: ١ = أقل كمية · ٢ = كاش فقط · ٣ = أقل قيمة لإجمالي الطلب. وتاريخا البداية والنهاية يُحدَّدان مرة واحدة بشاشة الرفع ويُعمَّمان على كل أصناف الملف.',
  note_en = 'The offer condition is written as its code: 1 = minimum quantity · 2 = cash only · 3 = minimum order value. Start and end dates are set once on the upload screen and applied to every item in the file.',
  lands = 'part_offers',
  -- the window is set on the upload screen, so requiring it as a column rejected every correctly
  -- filled file before the shared value was ever read
  columns = jsonb_build_array(
    jsonb_build_object('key','part_number','label_en','part_number','label_ar','رقم القطعة','required',true,
                       'note_en','Must already exist in the catalog','note_ar','يجب أن يكون معرَّفًا سابقًا'),
    jsonb_build_object('key','part_class','label_en','part_class','label_ar','الصنف','required',true,
                       'note_en','Must match the class already defined','note_ar','مطابق للصنف المعرَّف سابقًا'),
    jsonb_build_object('key','offer_price','label_en','offer_price','label_ar','سعر العرض','required',true,
                       'note_en','After discount, before VAT, SAR','note_ar','بعد الخصم، قبل الضريبة، SAR'),
    jsonb_build_object('key','starts_on','label_en','starts_on','label_ar','بداية العرض','required',false,
                       'note_en','Optional — filled from the offer window on the upload screen if left empty',
                       'note_ar','اختياري — يُملأ من نافذة العرض بشاشة الرفع إن تُرك فارغًا'),
    jsonb_build_object('key','ends_on','label_en','ends_on','label_ar','نهاية العرض','required',false,
                       'note_en','Optional — filled from the offer window on the upload screen if left empty',
                       'note_ar','اختياري — يُملأ من نافذة العرض بشاشة الرفع إن تُرك فارغًا'),
    jsonb_build_object('key','qty_limit','label_en','qty_limit','label_ar','حد الكمية','required',false))
where template_key = 'offers';

update qvm_new_apps.upload_templates set
  icon = '🚢',
  screen_fields = jsonb_build_array(
    jsonb_build_object('ar','الطرف المصدر — المورد','en','Source party — the vendor'),
    jsonb_build_object('ar','بلد الاستيراد (عام)','en','Import country (shared)'),
    jsonb_build_object('ar','شرط الدفع (عام)','en','Payment terms (shared)'),
    jsonb_build_object('ar','تاريخ نهاية الطلب (عام)','en','Request end date (shared)'),
    jsonb_build_object('ar','تاريخ الوصول المتوقع (عام)','en','Expected arrival date (shared)')),
  note_ar = 'أي عمود عام يُترك فارغًا في الملف يُملأ من القيم العامة التي تُحدَّد بعد الرفع؛ والقيمة المكتوبة في صف الصنف تغلب العامة. وشرط الدفع بالأرقام: ١ = كامل قبل الشحن · ٢ = عربون قبل الشحن · ٣ = كامل بعد الوصول · ٤ = عربون + آجل بعد الوصول.',
  note_en = 'A shared column left empty in the sheet is filled from the shared values set on this screen; a value written on the item row wins over the shared one. Payment terms as codes: 1 = paid in full before shipping · 2 = deposit before shipping · 3 = paid in full after arrival · 4 = deposit plus balance after arrival.',
  lands = 'group_import_requests',
  -- without a make and a class every imported item landed as an unqualified part number
  columns = jsonb_build_array(
    jsonb_build_object('key','part_number','label_en','part_number','label_ar','رقم القطعة','required',true,
                       'note_en','Raw','note_ar','خام — يُنظَّف آليًا'),
    jsonb_build_object('key','description','label_en','description','label_ar','الوصف','required',false),
    jsonb_build_object('key','make','label_en','make','label_ar','الماركة','required',true,
                       'note_en','BRAND','note_ar','بدونها الرقم غير فريد بالكتالوج'),
    jsonb_build_object('key','part_class','label_en','part_class','label_ar','الصنف','required',true,
                       'note_en','Genuine / OEM / Commercial / Used','note_ar','أصلي / OEM / تجاري / مستعمل'),
    jsonb_build_object('key','qty','label_en','qty','label_ar','أقل كمية للطلب','required',true),
    jsonb_build_object('key','target_price','label_en','target_price','label_ar','السعر من المصدر','required',false,
                       'note_en','Before VAT, SAR','note_ar','قبل الضريبة، SAR'),
    jsonb_build_object('key','origin_country','label_en','origin_country','label_ar','بلد الاستيراد','required',false,
                       'note_en','Shared or per item','note_ar','عام أو لكل صنف'),
    jsonb_build_object('key','payment_terms','label_en','payment_terms','label_ar','شرط الدفع','required',false,
                       'note_en','1–4, shared or per item','note_ar','١–٤ · عام أو لكل صنف'),
    jsonb_build_object('key','arrival_weeks','label_en','arrival_weeks','label_ar','مدة الوصول (أسابيع)','required',false),
    jsonb_build_object('key','request_end_date','label_en','request_end_date','label_ar','تاريخ نهاية الطلب','required',false,
                       'note_en','Optional — filled from the shared value','note_ar','اختياري — يُملأ من القيمة العامة'))
where template_key = 'group_import_request';

update qvm_new_apps.upload_templates set
  icon = '🔨',
  screen_fields = jsonb_build_array(
    jsonb_build_object('ar','سعر بداية المناقصة','en','Opening price'),
    jsonb_build_object('ar','قيمة المزايدة لكل مستخدم','en','Bid increment per bidder'),
    jsonb_build_object('ar','مبلغ ضمان المشاركة','en','Participation deposit'),
    jsonb_build_object('ar','بيانات التواصل','en','Contact details'),
    jsonb_build_object('ar','الموقع','en','Location'),
    jsonb_build_object('ar','ساعات المعاينة المتاحة','en','Viewing hours'),
    jsonb_build_object('ar','تاريخ فتح المزايدات','en','Bidding opens'),
    jsonb_build_object('ar','تاريخ نهاية المزاد','en','Auction closes')),
  note_ar = 'الملف يصف محتويات الاستوك (جرد الأصناف)؛ أما شروط المزاد والصور فتُحدَّد في شاشة الرفع وتُطبَّق على المزاد كله.',
  note_en = 'The sheet describes what the stock contains; the auction terms and the photos are set on this screen and apply to the whole auction.',
  lands = 'stock_auction_items',
  columns = jsonb_build_array(
    jsonb_build_object('key','part_number','label_en','part_number','label_ar','رقم القطعة','required',true,
                       'note_en','Raw','note_ar','خام — يُنظَّف آليًا'),
    jsonb_build_object('key','description','label_en','description','label_ar','وصف الصنف','required',false),
    jsonb_build_object('key','make','label_en','make','label_ar','الماركة','required',true,
                       'note_en','BRAND','note_ar','بدونها الرقم غير فريد بالكتالوج'),
    jsonb_build_object('key','part_class','label_en','part_class','label_ar','الصنف','required',false,
                       'note_en','Genuine / OEM / Commercial / Used','note_ar','أصلي / OEM / تجاري / مستعمل'),
    jsonb_build_object('key','qty','label_en','qty','label_ar','الكمية ضمن الاستوك','required',true),
    jsonb_build_object('key','reserve_price','label_en','reserve_price','label_ar','القيمة التقديرية','required',false,
                       'note_en','Before VAT, SAR','note_ar','قبل الضريبة، SAR'),
    jsonb_build_object('key','closes_on','label_en','closes_on','label_ar','تاريخ الإقفال','required',false,
                       'note_en','Optional — filled from the auction''s closing date','note_ar','اختياري — يُملأ من تاريخ نهاية المزاد'))
where template_key = 'stock_auction';
