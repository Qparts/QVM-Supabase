-- Synced from QVM/test branch applied migration history (version 20260218113131, name: fill_missing_user_branch_from_main_branch_mapping_v2)
-- Fill missing user_branch in qvm_new_apps.user_data using main branch branch-name mapping.
-- Fix: keep target-table references out of JOIN ... ON; put them in WHERE.

DELETE FROM public.temp_branch_mapping_completion;

INSERT INTO public.temp_branch_mapping_completion (email, user_branch_name, customer_id, company_name)
VALUES
  ('a.abueidhah@petromin.com','Rashid mall/KHOBAR',NULL,NULL),
  ('a.almarakshi@petromin.com','-',NULL,NULL),
  ('abdelkarimam@saptco.com.sa','-',NULL,NULL),
  ('abdouof@saptco.com.sa','Saptco - Jeddah',NULL,NULL),
  ('abdualmuneim@qparts.co','-',NULL,NULL),
  ('abdulkareem.aliakbar@petromin.com','Rabea',NULL,NULL),
  ('abdullah.nadeem@petromin.com','Branch 604.',NULL,NULL),
  ('abdulrahman@qparts.co','-',NULL,NULL),
  ('adham.aldini@petromin.com','Al Murabaland',NULL,NULL),
  ('a.elbedaly@petromin.com','Alkahrj',NULL,NULL),
  ('ahmed.abdullah@qparts.co','-',NULL,NULL),
  ('ahmedaha@saptco.com.sa','Saptco - Riyadh',NULL,NULL),
  ('ahmed.elazab@qparts.co','-',NULL,NULL),
  ('ahmed.jamali@petromin.com','Al-Safa Land',NULL,NULL),
  ('ahmed.sayed@petromin.com','Thumama',NULL,NULL),
  ('alaa.khedr196@gmail.com','C-Naseem',NULL,NULL),
  ('alaa.khedr@qparts.co','C-Naseem',NULL,NULL),
  ('aliao@almajdouie.com','Al Rakah',NULL,NULL),
  ('alsheikhmh@saptco.com.sa','Saptco - Jazan',NULL,NULL),
  ('aminah.alotaibi@petromin.com','Masif',NULL,NULL),
  ('ashwin.kumar@petromin.com','-',NULL,NULL),
  ('azza@qparts.co','-',NULL,NULL),
  ('bilal.sheikh@petromin.com','Qassim 359.',NULL,NULL),
  ('b.padia@petromin.com','-',NULL,NULL),
  ('eman.elsaim@qparts.co','-',NULL,NULL),
  ('eyad.fahad@petromin.com','Badiya',NULL,NULL),
  ('fageeraa@saptco.com.sa','-',NULL,NULL),
  ('g.thanigaivel@petromin.com','-',NULL,NULL),
  ('gulam.hussain@petromin.com','-',NULL,NULL),
  ('hassan.magdy@qparts.co','-',NULL,NULL),
  ('joud.fakoush@petromin.com','Masif',NULL,NULL),
  ('kalander.mafaz@petromin.com','Exit 13.',NULL,NULL),
  ('lalshanqiti@tawuniya.com','Tawuniya',NULL,NULL),
  ('loay.abbas@petromin.com','Al Narjis',NULL,NULL),
  ('mahadeer@autolead.sa','Maj-Khurais',NULL,NULL),
  ('mahmoud.goudah@petromin.com','Masif',NULL,NULL),
  ('majed.sayed@petromin.com','Masif',NULL,NULL),
  ('malik.azhar@petromin.com','Thumama',NULL,NULL),
  ('m.bata@petromin.com','AlQassim Buraidah',NULL,NULL),
  ('m.elafany@petromin.com','Nahada',NULL,NULL),
  ('mohamad.hamdan@limarcenter.com','Limar El-Shams',NULL,NULL),
  ('mohammed.alossaimi@shaheen-alarabia.com','Al-Munsiyah',NULL,NULL),
  ('mohammeds@autolead.sa','ELKhaleeg',NULL,NULL),
  ('mohammed.zahid@petromin.com','Badiya',NULL,NULL),
  ('mohamed.bilal@qparts.co','-',NULL,NULL),
  ('mohamed.salah@qparts.co','-',NULL,NULL),
  ('mohannad@qparts.co','-',NULL,NULL),
  ('m.raoofuddin@petromin.com','Thumama',NULL,NULL),
  ('mw-80101-jcs@joil.com.sa','Al-Munsiyah',NULL,NULL),
  ('nsamat2012@hotmail.com','Nasmat',NULL,NULL),
  ('omar.moh@qparts.co','-',NULL,NULL),
  ('omar@qparts.co','-',NULL,NULL),
  ('qparts8@gmail.com','-',NULL,NULL),
  ('razaz@qparts.co','-',NULL,NULL),
  ('sara.belal@qparts.co','-',NULL,NULL),
  ('tech-dream@hotmail.com','AlManar',NULL,NULL),
  ('turbocare27@gmail.com','Turbo Car Care',NULL,NULL),
  ('workshop@gmail.com','AlMaghrizat',NULL,NULL);

-- 1) Strict mapping: branch_name + company(list_data_id) must match
UPDATE qvm_new_apps.user_data ud
SET user_branch = cb.customer_id
FROM public.temp_branch_mapping_completion t
JOIN qvm_new_apps.client_branches cb
  ON cb.branch_name = t.user_branch_name
WHERE ud.user_branch IS NULL
  AND LOWER(TRIM(ud.email)) = t.email
  AND cb.list_data_id = ud.user_company
  AND t.user_branch_name IS NOT NULL
  AND TRIM(t.user_branch_name) <> ''
  AND TRIM(t.user_branch_name) <> '-';

-- 2) Fallback mapping: branch_name only (if strict mapping fails)
UPDATE qvm_new_apps.user_data ud
SET user_branch = cb.customer_id
FROM public.temp_branch_mapping_completion t
JOIN qvm_new_apps.client_branches cb
  ON cb.branch_name = t.user_branch_name
WHERE ud.user_branch IS NULL
  AND LOWER(TRIM(ud.email)) = t.email
  AND t.user_branch_name IS NOT NULL
  AND TRIM(t.user_branch_name) <> ''
  AND TRIM(t.user_branch_name) <> '-';;
