-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.


create table if not exists qvm_new_apps.report_permission_grants (
  grant_id    bigint generated always as identity primary key,
  name        text   not null,
  role        text,
  scope       text   not null check (scope in ('own','team','all')),
  created_by  uuid,
  updated_by  uuid,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists qvm_new_apps.report_permission_grant_users (
  grant_id  bigint not null references qvm_new_apps.report_permission_grants(grant_id) on delete cascade,
  user_id   uuid   not null,
  primary key (grant_id, user_id)
);

create table if not exists qvm_new_apps.report_permission_page_access (
  grant_id    bigint  not null references qvm_new_apps.report_permission_grants(grant_id) on delete cascade,
  page_key    text    not null check (page_key in ('overview','workshop','purchasing','partfinder','vendors')),
  can_view    boolean not null default false,
  can_export  boolean not null default false,
  primary key (grant_id, page_key),
  constraint export_requires_view check (not can_export or can_view)
);

create table if not exists qvm_new_apps.report_permission_section_visibility (
  grant_id     bigint  not null references qvm_new_apps.report_permission_grants(grant_id) on delete cascade,
  page_key     text    not null check (page_key in ('overview','workshop','purchasing','partfinder','vendors')),
  section_key  text    not null,
  is_visible   boolean not null default true,
  primary key (grant_id, page_key, section_key)
);

create table if not exists qvm_new_apps.report_access_audit_log (
  audit_id      bigint generated always as identity primary key,
  user_id       uuid,
  report_page   text not null,
  action        text not null check (action in ('view','export')),
  scope_applied text,
  created_at    timestamptz not null default now()
);
create index if not exists idx_report_audit_created on qvm_new_apps.report_access_audit_log (created_at desc);
create index if not exists idx_report_audit_page    on qvm_new_apps.report_access_audit_log (report_page);

create table if not exists qvm_new_apps.report_settings_thresholds (
  key                 text primary key,
  label               text    not null,
  value               numeric not null,
  value_unit          text,
  used_in_description text,
  min_value           numeric,
  max_value           numeric,
  updated_by          uuid,
  updated_at          timestamptz not null default now()
);

insert into qvm_new_apps.report_settings_thresholds
  (key, label, value, value_unit, used_in_description, min_value, max_value)
values
  ('order_delay_threshold_days','Order delay threshold',3,'days',
     'Purchasing report — flags orders whose processing time exceeds this.',0,365),
  ('acceptable_price_deviation_pct','Acceptable price deviation',10,'%',
     'Purchasing report — deviation classification vs. reference price.',0,100),
  ('bonus_ar_eligibility_days','Bonus AR eligibility condition',30,'days',
     'Overview report — max days-to-collect for AR bonus eligibility.',0,365),
  ('vendor_delivery_sla_target_pct','Vendor delivery SLA target',90,'%',
     'Vendors report — target on-time delivery rate.',0,100),
  ('vendor_concentration_threshold_pct','Vendor concentration threshold',30,'%',
     'Vendors report — flags over-reliance on a single vendor.',0,100),
  ('workshop_response_speed_threshold_hours','Workshop response-speed threshold',4,'hours',
     'Workshop report — max acceptable first-response time.',0,168)
on conflict (key) do nothing;
