-- The integrations marketplace: what is on offer, and what each plan actually sells.
--
-- Kept as data, not as a component full of hard-coded cards. A price, a limit or a new service is
-- then a row — and, more importantly, the limit a company bought last month can still be read next
-- year, which a constant in a bundle cannot.
create table if not exists qvm_new_apps.integration_services (
  service_key text primary key,
  name_ar     text not null,
  name_en     text not null,
  -- 'shipping' | 'notifications' | 'tools' — the filter chips on the page.
  category    text not null,
  -- How it is sold and operated:
  --   'plan'    tiered monthly packages with quotas (WhatsApp, email, AI, part numbers)
  --   'connect' no package: you attach your own account and pay per use (Mrsool)
  --   'soon'    announced, not available — the card is drawn disabled rather than hidden, so the
  --             roadmap is visible instead of being a support question
  kind        text not null check (kind in ('plan','connect','soon')),
  tagline_ar  text,
  tagline_en  text,
  blurb_ar    text,
  blurb_en    text,
  -- Two initials for the card's tile, and its colour. Data because the catalogue is data.
  badge       text,
  accent      text,
  sort_order  integer not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

alter table qvm_new_apps.integration_services enable row level security;

-- ── Plans ──────────────────────────────────────────────────────────────────────────────────────
-- `limits` is jsonb because every service sells a different shape of allowance: messages a month,
-- numbers connected, gigabytes, lookups. A column per metric would be a migration every time a
-- service is added, and most of them null.
--
-- The quota engine reads keys out of this object; nothing else interprets it, so a new metric is a
-- new key here plus one consumer that checks it.
create table if not exists qvm_new_apps.integration_plans (
  plan_id     bigserial primary key,
  service_key text not null references qvm_new_apps.integration_services(service_key) on delete cascade,
  plan_key    text not null,
  name_ar     text not null,
  name_en     text not null,
  price       numeric not null check (price >= 0),
  period      text not null default 'monthly' check (period in ('monthly','yearly')),
  limits      jsonb not null default '{}'::jsonb,
  -- Shown to the buyer as «الأكثر اختيارًا». One per service, not enforced — a nudge, not a rule.
  is_popular  boolean not null default false,
  sort_order  integer not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (service_key, plan_key)
);

alter table qvm_new_apps.integration_plans enable row level security;

insert into qvm_new_apps.integration_services
  (service_key, name_ar, name_en, category, kind, tagline_ar, tagline_en, blurb_ar, blurb_en, badge, accent, sort_order)
values
  ('mrsool', 'مرسول', 'Mrsool', 'shipping', 'connect',
   'شركة شحن · ربط مباشر', 'Carrier · direct connect',
   'ناقل خارجي بديل للتوصيل الفوري داخل المدينة عند عدم توفر أسطول داخلي.',
   'An outside carrier for same-city delivery when no internal fleet is available.',
   'M', '#b91c1c', 10),
  ('whatsapp', 'WhatsApp Business', 'WhatsApp Business', 'notifications', 'plan',
   'إشعارات · باقات', 'Notifications · packages',
   'باقات مرتبطة بعدد الأرقام المربوطة + مساحة التخزين + عدد الرسائل الشهرية.',
   'Packages by connected numbers, storage and monthly message volume.',
   'W', '#16a34a', 20),
  ('email', 'البريد الإلكتروني', 'Email', 'notifications', 'plan',
   'إشعارات · باقات', 'Notifications · packages',
   'باقات مرتبطة بعدد صناديق البريد المربوطة + مساحة التخزين + عدد الرسائل الشهرية.',
   'Packages by connected mailboxes, storage and monthly message volume.',
   'E', '#2563eb', 30),
  ('ai', 'الذكاء الاصطناعي', 'AI', 'tools', 'plan',
   'أتمتة · باقات شهرية', 'Automation · monthly packages',
   'باقات استخدام شهرية — كل باقة تمنحك رصيد استخدام الذكاء الاصطناعي للشهر.',
   'Monthly usage packages — each grants a month of AI credit.',
   'AI', '#7c3aed', 40),
  ('part_number', 'استخراج رقم القطعة', 'Part number lookup', 'tools', 'plan',
   'أتمتة · باقات شهرية', 'Automation · monthly packages',
   'باقات شهرية — كل باقة تمنحك رصيد عمليات استخراج لرقم القطعة.',
   'Monthly packages — each grants a number of part-number lookups.',
   'PN', '#0891b2', 50),
  ('smsa', 'SMSA', 'SMSA', 'shipping', 'soon',
   'شركة شحن', 'Carrier',
   'تسعير ثابت بجدول أسعار شحن بين المدن بدون تتبع مباشر.',
   'Flat intercity pricing from a rate table, without live tracking.',
   'S', '#0f172a', 60),
  ('logisticsco', 'LogisticsCo — مقدم خدمة', 'LogisticsCo — provider', 'shipping', 'soon',
   'خدمة التوصيل · مقدم خدمة', 'Delivery · service provider',
   'سجّل مركباتك وسائقيك، استقبل مهام التوصيل، وشارك في مزايدات الشحنات المفتوحة داخل مدنك.',
   'Register vehicles and drivers, take delivery jobs, and bid on open shipments in your cities.',
   'LC', '#334155', 70)
on conflict (service_key) do nothing;

-- The numbers come straight off the design. Two notes where it needed a decision:
--
-- · WhatsApp's daily cap per number read Starter 200 / Business 600 / Pro 500 — Pro lower than
--   Business, which cannot be what was meant. Pro is set to 1,000 here: above Business, and in
--   step with the rest of the ladder. It is one row to change if the intended figure was different.
-- · «غير محدود» is stored as null rather than a very large number, so a check for «is there a
--   limit» is `is null` rather than a guess about how big counts as infinite.
insert into qvm_new_apps.integration_plans
  (service_key, plan_key, name_ar, name_en, price, limits, is_popular, sort_order)
values
  ('whatsapp', 'starter',  'Starter',  'Starter',  149,
   '{"numbers":1,"messages_month":3000,"daily_per_number":200,"storage_gb":2,"media_months":3,"text_months":12}', false, 10),
  ('whatsapp', 'business', 'Business', 'Business', 299,
   '{"numbers":1,"messages_month":10000,"daily_per_number":600,"storage_gb":10,"media_months":6,"text_months":24}', true, 20),
  ('whatsapp', 'pro',      'Pro',      'Pro',      699,
   '{"numbers":3,"messages_month":30000,"daily_per_number":1000,"storage_gb":40,"media_months":12,"text_months":null}', false, 30),

  ('email', 'basic',    'أساسية', 'Basic',    149,
   '{"mailboxes":3,"messages_month":5000,"storage_gb":5}',    false, 10),
  ('email', 'standard', 'قياسية', 'Standard', 399,
   '{"mailboxes":10,"messages_month":20000,"storage_gb":25}', true,  20),
  ('email', 'advanced', 'متقدمة', 'Advanced', 899,
   '{"mailboxes":30,"messages_month":75000,"storage_gb":100}', false, 30),

  ('part_number', 'basic',    'أساسية', 'Basic',    249,  '{"lookups_month":500}',  false, 10),
  ('part_number', 'standard', 'قياسية', 'Standard', 799,  '{"lookups_month":2000}', true,  20),
  ('part_number', 'advanced', 'متقدمة', 'Advanced', 1799, '{"lookups_month":6000}', false, 30),

  -- AI is metered in riyals rather than in calls, because that is how it is already billed to the
  -- wallet: a package buys a month's worth of spend, and the trigger that charges per call is what
  -- consumes it.
  ('ai', 'basic',    'أساسية', 'Basic',    249,  '{"credit_month":250}',  false, 10),
  ('ai', 'standard', 'قياسية', 'Standard', 799,  '{"credit_month":850}',  true,  20),
  ('ai', 'advanced', 'متقدمة', 'Advanced', 1799, '{"credit_month":2000}', false, 30)
on conflict (service_key, plan_key) do nothing;
