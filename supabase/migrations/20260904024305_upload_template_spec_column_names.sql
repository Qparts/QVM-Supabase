-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The templates now carry the column names the spec prints: in_part_number, ID_make,
-- ID_part_class, ID_Vendor_name and Vendor_City.
--
-- These are not labels. sheet_to_json keys every row by the header cell verbatim, and the
-- staging functions read the row by that key — so the header in the file, the column in
-- the template, and the field the server reads are one string in three places.
--
-- Two things make the change safe to land on a system that already holds rows:
--
--  · reads go through upload_raw_get, which tries the new name, then the old one. The
--    batches staged before today still recompute, and part_number keeps working in the
--    two templates the spec did not rename it in.
--  · the lookup is case-insensitive. The downloaded template always carries the exact
--    case, but headers get retyped by hand, and «id_make» failing silently as an empty
--    brand is the kind of bug nobody reports — the file just quietly loses its brands.

create or replace function qvm_new_apps.upload_raw_get(p_raw jsonb, variadic p_keys text[])
returns text
language sql
immutable
as $function$
  select x.v
    from unnest(p_keys) with ordinality k(want, ord)
    cross join lateral (
      select nullif(btrim(e.value), '') as v
        from jsonb_each_text(p_raw) e
       where lower(e.key) = lower(k.want)
       limit 1
    ) x
   where x.v is not null
   order by k.ord
   limit 1;
$function$;

-- ── the three templates ───────────────────────────────────────────────────────
-- Rewritten as whole column lists rather than patched key by key: the order on the
-- screen is the order in the downloaded sheet, and it is easier to read the intended
-- file here than to reconstruct it from a series of edits.

update qvm_new_apps.upload_templates set columns = $j$[
  {"key":"in_part_number","label_en":"in_part_number","label_ar":"رقم القطعة",
   "note_en":"Raw","note_ar":"كما هو — يُنظَّف آليًا","required":true},
  {"key":"name_ar","label_en":"name_ar","label_ar":"الاسم بالعربية",
   "note_en":"Auto-filled when left blank","note_ar":"يُكمَل تلقائيًا إن تُرك فارغًا","required":false},
  {"key":"name_en","label_en":"name_en","label_ar":"الاسم بالإنجليزية",
   "note_en":"Optional","note_ar":"اختياري","required":false},
  {"key":"ID_make","label_en":"ID_make","label_ar":"الماركة",
   "note_en":"BRAND","note_ar":"العلامة التجارية","required":true},
  {"key":"ID_part_class","label_en":"ID_part_class","label_ar":"الصنف",
   "note_en":"Genuine / OEM / Commercial / Used","note_ar":"أصلي / OEM / تجاري / مستعمل","required":true},
  {"key":"agency_price","label_en":"agency_price","label_ar":"سعر الوكالة",
   "note_en":"As stated by the uploading vendor","note_ar":"مصدره المورد الرافع","required":true},
  {"key":"dealer_agency_discount_pct","label_en":"dealer_agency_discount_pct","label_ar":"نسبة خصم الوكيل",
   "note_en":"Percentage","note_ar":"نسبة مئوية","required":false},
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
  {"key":"ID_make","label_en":"ID_make","label_ar":"العلامة",
   "note_en":"BRAND","note_ar":"العلامة التجارية","required":false},
  {"key":"ID_part_class","label_en":"ID_part_class","label_ar":"صنف القطعة",
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

update qvm_new_apps.upload_templates set columns = $j$[
  {"key":"part_number","label_en":"part_number","label_ar":"رقم القطعة",
   "note_en":"Raw","note_ar":"كما هو — يُنظَّف آليًا","required":true},
  {"key":"ID_Vendor_name","label_en":"ID_Vendor_name","label_ar":"اسم المورد",
   "note_en":"Required","note_ar":"إجباري","required":true},
  {"key":"Vendor_City","label_en":"Vendor_City","label_ar":"مدينة المورد",
   "note_en":"Required","note_ar":"إجباري","required":true},
  {"key":"name_ar","label_en":"name_ar","label_ar":"الاسم بالعربية",
   "note_en":"Auto-filled when left blank","note_ar":"يُكمَل تلقائيًا إن تُرك فارغًا","required":false},
  {"key":"name_en","label_en":"name_en","label_ar":"الاسم بالإنجليزية",
   "note_en":"Optional","note_ar":"اختياري","required":false},
  {"key":"ID_make","label_en":"ID_make","label_ar":"الماركة",
   "note_en":"BRAND","note_ar":"العلامة التجارية","required":true},
  {"key":"ID_part_class","label_en":"ID_part_class","label_ar":"الصنف",
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
