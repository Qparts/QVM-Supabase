-- A plan is compared row by row, and the rows are data.
--
-- The design's plan sheet is a matrix: nine rows down the side, one column per tier, the chosen
-- one picked out. Building that from a hard-coded list of rows in the component would put the
-- catalogue back in the bundle — a new metric, a renamed row or a new service would all be code
-- again.
--
-- `metrics` is the ordered spec for that table: which keys to show, in what order, under what
-- label, and how to render each one. A number, a boolean tick, a word, or «غير محدود» for null
-- are four different renderings and the data says which.
alter table qvm_new_apps.integration_services
  add column if not exists metrics jsonb not null default '[]'::jsonb;

comment on column qvm_new_apps.integration_services.metrics is
  'Ordered spec for the plan comparison table: [{key, label_ar, label_en, format}]. format is '
  'number | bool | text — how to draw the value, since a tick and a quantity are not the same row.';

update qvm_new_apps.integration_services set metrics = '[
  {"key":"price",            "label_ar":"السعر شهريًا",          "label_en":"Monthly price",        "format":"price"},
  {"key":"numbers",          "label_ar":"الأرقام المتصلة",        "label_en":"Connected numbers",    "format":"number"},
  {"key":"messages_month",   "label_ar":"رسائل صادرة / شهر",      "label_en":"Messages / month",     "format":"number"},
  {"key":"daily_per_number", "label_ar":"سقف يومي / رقم",         "label_en":"Daily cap per number", "format":"number"},
  {"key":"storage_gb",       "label_ar":"التخزين",                "label_en":"Storage",              "format":"gb"},
  {"key":"media_months",     "label_ar":"الاحتفاظ بالوسائط",      "label_en":"Media retention",      "format":"months"},
  {"key":"text_months",      "label_ar":"الاحتفاظ بالنصوص",       "label_en":"Text retention",       "format":"months"},
  {"key":"webhooks",         "label_ar":"Webhooks / API",         "label_en":"Webhooks / API",       "format":"bool"},
  {"key":"support",          "label_ar":"الدعم",                  "label_en":"Support",              "format":"text"}
]'::jsonb
 where service_key = 'whatsapp';

update qvm_new_apps.integration_services set metrics = '[
  {"key":"price",          "label_ar":"السعر شهريًا",       "label_en":"Monthly price",     "format":"price"},
  {"key":"mailboxes",      "label_ar":"صناديق البريد",      "label_en":"Mailboxes",         "format":"number"},
  {"key":"messages_month", "label_ar":"رسائل / شهر",        "label_en":"Messages / month",  "format":"number"},
  {"key":"storage_gb",     "label_ar":"التخزين",            "label_en":"Storage",           "format":"gb"}
]'::jsonb
 where service_key = 'email';

update qvm_new_apps.integration_services set metrics = '[
  {"key":"price",         "label_ar":"السعر شهريًا",        "label_en":"Monthly price",   "format":"price"},
  {"key":"lookups_month", "label_ar":"عمليات استخراج / شهر","label_en":"Lookups / month", "format":"number"}
]'::jsonb
 where service_key = 'part_number';

update qvm_new_apps.integration_services set metrics = '[
  {"key":"price",        "label_ar":"السعر شهريًا",              "label_en":"Monthly price",  "format":"price"},
  {"key":"credit_month", "label_ar":"رصيد الذكاء الاصطناعي / شهر","label_en":"AI credit / month","format":"price"}
]'::jsonb
 where service_key = 'ai';

-- The two rows the plans did not carry yet. Both come straight off the design sheet.
--
-- They live in `limits` beside the quotas even though neither is metered, because the comparison
-- table reads one object per plan — splitting «what you get» across two places would mean the
-- sheet and the quota engine disagree about where a plan's promises are written down.
update qvm_new_apps.integration_plans
   set limits = limits || '{"webhooks":true,"support":"تذاكر"}'::jsonb
 where service_key = 'whatsapp' and plan_key = 'starter';
update qvm_new_apps.integration_plans
   set limits = limits || '{"webhooks":true,"support":"تذاكر + واتساب"}'::jsonb
 where service_key = 'whatsapp' and plan_key = 'business';
update qvm_new_apps.integration_plans
   set limits = limits || '{"webhooks":true,"support":"مخصص"}'::jsonb
 where service_key = 'whatsapp' and plan_key = 'pro';

-- ── «1 رقم مربوط حاليًا» ────────────────────────────────────────────────────────────────────────
-- wa_accounts and email_accounts are platform-wide, the same way the carrier credentials were.
-- Without an owner the count cannot be answered per company, so the header line would have been a
-- guess dressed as a fact.
--
-- Nullable, and null means «the platform's» — the existing inbox keeps working untouched and a
-- company's own connections are the ones that count against its plan.
alter table qvm_new_apps.wa_accounts
  add column if not exists company_id integer references qvm_new_apps.client_companies(company_id) on delete set null;
alter table qvm_new_apps.email_accounts
  add column if not exists company_id integer references qvm_new_apps.client_companies(company_id) on delete set null;

comment on column qvm_new_apps.wa_accounts.company_id is
  'Whose number this is. Null is the platform''s, which is what every row was before the '
  'marketplace existed — it is not counted against any company''s plan.';

create index if not exists wa_accounts_company_idx on qvm_new_apps.wa_accounts (company_id);
create index if not exists email_accounts_company_idx on qvm_new_apps.email_accounts (company_id);

-- How many of the thing a plan counts are actually connected right now. Answered from the real
-- tables rather than from a usage counter, because a number that was connected and then removed
-- should stop counting the moment it is removed — a counter would have to be decremented by
-- somebody remembering to.
create or replace function qvm_new_apps.integration_connected(
  p_company_id integer,
  p_service    text)
returns integer
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select case p_service
    when 'whatsapp' then (select count(*)::int from qvm_new_apps.wa_accounts
                           where company_id = p_company_id)
    when 'email'    then (select count(*)::int from qvm_new_apps.email_accounts
                           where company_id = p_company_id)
    else 0 end;
$$;

-- Carried onto every card, with the metric spec.
do $do$
declare
  v_def  text := pg_get_functiondef('qvm_new_apps.integrations_market(integer)'::regprocedure);
  v_old  text := '    ''badge'', s.badge, ''accent'', s.accent, ''logo_url'', s.logo_url,';
  v_new  text := '    ''badge'', s.badge, ''accent'', s.accent, ''logo_url'', s.logo_url,
    ''metrics'', s.metrics,
    ''connected'', qvm_new_apps.integration_connected(v_co, s.service_key),';
  v_hits integer;
begin
  v_hits := (length(v_def) - length(replace(v_def, v_old, ''))) / greatest(length(v_old), 1);
  if v_hits <> 1 then
    raise exception 'integrations_market: expected the badge line once, found %', v_hits;
  end if;
  execute replace(v_def, v_old, v_new);
end
$do$;

grant execute on function qvm_new_apps.integration_connected(integer, text)
  to authenticated, service_role;
