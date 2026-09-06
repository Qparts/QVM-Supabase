-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The ID_ naming is dropped, and the agency list asks for less.
--
-- The prefixes came from a spec that has since been withdrawn, so the columns go back to
-- the names the rest of the module already used — which also puts the three templates back
-- in step with each other rather than one of them spelling the same field differently.
--
-- On the agency list only the part number and the agency price are now required: a price
-- list that names its parts and prices them is complete, and refusing a file because a
-- brand column was left blank rejected rows that had everything anyone needed. The dealer
-- discount percentage column goes entirely.
--
-- Nothing has to be re-parsed for this: the readers already take either spelling, and the
-- required check reads the template, so relaxing it here relaxes it everywhere at once.

update qvm_new_apps.upload_templates set columns = $j$[
  {"key":"part_number","label_en":"part_number","label_ar":"رقم القطعة",
   "note_en":"Raw","note_ar":"كما هو — يُنظَّف آليًا","required":true},
  {"key":"name_ar","label_en":"name_ar","label_ar":"الاسم بالعربية",
   "note_en":"Auto-filled when left blank","note_ar":"يُكمَل تلقائيًا إن تُرك فارغًا","required":false},
  {"key":"name_en","label_en":"name_en","label_ar":"الاسم بالإنجليزية",
   "note_en":"Optional","note_ar":"اختياري","required":false},
  {"key":"make","label_en":"make","label_ar":"الماركة",
   "note_en":"BRAND","note_ar":"العلامة التجارية","required":false},
  {"key":"part_class","label_en":"part_class","label_ar":"الصنف",
   "note_en":"Genuine / OEM / Commercial / Used","note_ar":"أصلي / OEM / تجاري / مستعمل","required":false},
  {"key":"agency_price","label_en":"agency_price","label_ar":"سعر الوكالة",
   "note_en":"As stated by the uploading vendor","note_ar":"مصدره المورد الرافع","required":true},
  {"key":"agency_price_after_discount","label_en":"agency_price_after_discount","label_ar":"سعر الوكالة بعد الخصم",
   "note_en":"Before VAT, SAR","note_ar":"قبل الضريبة، بالريال","required":false}
]$j$::jsonb
where template_key = 'agency_price_list';

update qvm_new_apps.upload_templates set columns = $j$[
  {"key":"part_number","label_en":"part_number","label_ar":"رقم القطعة",
   "note_en":"Raw","note_ar":"كما هو","required":true},
  {"key":"name_ar","label_en":"name_ar","label_ar":"الاسم بالعربية",
   "note_en":"Auto-filled when left blank","note_ar":"يُكمَل تلقائيًا إن تُرك فارغًا","required":false},
  {"key":"name_en","label_en":"name_en","label_ar":"الاسم بالإنجليزية",
   "note_en":"Optional","note_ar":"اختياري","required":false},
  {"key":"make","label_en":"make","label_ar":"العلامة",
   "note_en":"BRAND","note_ar":"العلامة التجارية","required":false},
  {"key":"part_class","label_en":"part_class","label_ar":"صنف القطعة",
   "note_en":"Genuine / OEM / commercial / used","note_ar":"أصلي / OEM / تجاري / مستعمل","required":false},
  {"key":"qty","label_en":"qty","label_ar":"الكمية",
   "note_en":"Or available / not available","note_ar":"أو متوفر / غير متوفر","required":true},
  {"key":"wholesale_price","label_en":"wholesale_price","label_ar":"سعر الجملة",
   "note_en":"Before VAT, SAR","note_ar":"قبل الضريبة، بالريال","required":true},
  {"key":"retail_price","label_en":"retail_price","label_ar":"سعر التجزئة",
   "note_en":"Before VAT, SAR","note_ar":"قبل الضريبة، بالريال","required":false},
  {"key":"before_discount_price","label_en":"before_discount_price","label_ar":"السعر قبل الخصم",
   "note_en":"Before VAT, SAR","note_ar":"قبل الضريبة، بالريال","required":false}
]$j$::jsonb
where template_key = 'stock_on_hand';

-- The city stays: it was missing altogether before, and it is what tells two branches of
-- the same supplier apart. Only its name loses the prefix.
update qvm_new_apps.upload_templates set columns = $j$[
  {"key":"part_number","label_en":"part_number","label_ar":"رقم القطعة",
   "note_en":"Raw","note_ar":"كما هو — يُنظَّف آليًا","required":true},
  {"key":"supplier_name","label_en":"supplier_name","label_ar":"اسم المورد",
   "note_en":"Required","note_ar":"إجباري","required":true},
  {"key":"city","label_en":"city","label_ar":"مدينة المورد",
   "note_en":"Required","note_ar":"إجباري","required":true},
  {"key":"name_ar","label_en":"name_ar","label_ar":"الاسم بالعربية",
   "note_en":"Auto-filled when left blank","note_ar":"يُكمَل تلقائيًا إن تُرك فارغًا","required":false},
  {"key":"name_en","label_en":"name_en","label_ar":"الاسم بالإنجليزية",
   "note_en":"Optional","note_ar":"اختياري","required":false},
  {"key":"make","label_en":"make","label_ar":"الماركة",
   "note_en":"BRAND","note_ar":"العلامة التجارية","required":false},
  {"key":"part_class","label_en":"part_class","label_ar":"الصنف",
   "note_en":"Genuine / OEM / Commercial / Used","note_ar":"أصلي / OEM / تجاري / مستعمل","required":false},
  {"key":"qty","label_en":"qty","label_ar":"الكمية",
   "note_en":"Or available / not available","note_ar":"أو متوفر / غير متوفر","required":false},
  {"key":"purchase_date","label_en":"purchase_date","label_ar":"تاريخ الشراء",
   "note_en":"YYYY-MM-DD","note_ar":"سنة-شهر-يوم","required":true},
  {"key":"wholesale_price","label_en":"wholesale_price","label_ar":"سعر الجملة",
   "note_en":"Before VAT, SAR","note_ar":"قبل الضريبة، بالريال","required":true},
  {"key":"retail_price","label_en":"retail_price","label_ar":"سعر التجزئة",
   "note_en":"Before VAT, SAR","note_ar":"قبل الضريبة، بالريال","required":false},
  {"key":"before_discount_price","label_en":"before_discount_price","label_ar":"السعر قبل الخصم",
   "note_en":"Before VAT, SAR","note_ar":"قبل الضريبة، بالريال","required":false}
]$j$::jsonb
where template_key = 'past_purchases';
