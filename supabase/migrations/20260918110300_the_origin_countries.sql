-- The origin list, from the team's sheet, in the sheet's own order.
--
-- "Genuine" heads the list and is not a country. It is there because the sheet says so: when the
-- part class is Genuine the origin is Genuine, because a genuine part's origin is the marque, not a
-- factory address. It carries the sentinel code GEN so the ISO-2 uniqueness still holds and nothing
-- downstream has to special-case a NULL.
INSERT INTO qvm_new_apps.origin_countries (code, name_en, name_ar, sort_order)
VALUES
  ('GEN', 'Genuine',              'أصلي',             1),
  ('JP',  'Japan',                'اليابان',           2),
  ('KR',  'South Korea',          'كوريا الجنوبية',    3),
  ('CN',  'China',                'الصين',             4),
  ('TW',  'Taiwan',               'تايوان',            5),
  ('TH',  'Thailand',             'تايلاند',           6),
  ('ID',  'Indonesia',            'إندونيسيا',         7),
  ('MY',  'Malaysia',             'ماليزيا',           8),
  ('IN',  'India',                'الهند',             9),
  ('VN',  'Vietnam',              'فيتنام',           10),
  ('DE',  'Germany',              'ألمانيا',          11),
  ('FR',  'France',               'فرنسا',            12),
  ('IT',  'Italy',                'إيطاليا',          13),
  ('ES',  'Spain',                'إسبانيا',          14),
  ('GB',  'United Kingdom',       'المملكة المتحدة',  15),
  ('PL',  'Poland',               'بولندا',           16),
  ('CZ',  'Czech Republic',       'التشيك',           17),
  ('TR',  'Türkiye',              'تركيا',            18),
  ('US',  'United States',        'الولايات المتحدة', 19),
  ('MX',  'Mexico',               'المكسيك',          20),
  ('CA',  'Canada',               'كندا',             21),
  ('BR',  'Brazil',               'البرازيل',         22),
  ('AE',  'United Arab Emirates', 'الإمارات',         23),
  ('SA',  'Saudi Arabia',         'السعودية',         24)
ON CONFLICT DO NOTHING;

-- The brand-class list, readable without a session.
--
-- get_brand_classes has always insisted on a login, which is why the magic-link page was handed the
-- same rows through get_vendor_quotation_extras_by_token instead. That is a reference list -- what
-- grades exist in the catalogue -- and now that the grid has a grade column on both screens it is
-- simpler to have one way to ask for it. Same shape as list_part_brands, next to it.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_brand_classes()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'brand_class_id', ld.list_data_id,
           'brand_class_name', ld.list_data) ORDER BY ld.list_data_id), '[]'::jsonb)
    FROM qvm_new_apps.list_data ld
    JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id
   WHERE l.list_name = 'brand_class';
$function$;

CREATE OR REPLACE FUNCTION public.list_brand_classes()
 RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $$ SELECT qvm_new_apps.list_brand_classes(); $$;

REVOKE ALL ON FUNCTION public.list_brand_classes() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_brand_classes() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_brand_classes() TO anon, authenticated, service_role;
