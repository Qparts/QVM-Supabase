-- An integration credential can belong to a company.
--
-- carrier_credentials and service_credentials were built when Qparts talked to Mrsool and to
-- Gemini on everyone's behalf: one key, one webhook, one environment for the whole platform. That
-- was right for what was being asked then. It is wrong for a marketplace where each company brings
-- its own account, because one company saving a token would save it for the other sixteen.
--
-- company_id is NULLABLE and null means «the platform's». A company's own row wins; with none, the
-- platform row is used. That is what keeps the AI working — it has exactly one platform row today —
-- while letting any company override it without a migration per company.
--
-- Two partial unique indexes rather than one constraint including company_id: NULL is not equal to
-- NULL in a unique index, so a plain UNIQUE (carrier_id, company_id, environment) would happily
-- accept two platform defaults for the same carrier.
alter table qvm_new_apps.carrier_credentials
  add column if not exists company_id integer references qvm_new_apps.client_companies(company_id) on delete cascade;

alter table qvm_new_apps.carrier_credentials
  drop constraint if exists carrier_credentials_carrier_id_environment_key;

create unique index if not exists carrier_credentials_platform_uniq
  on qvm_new_apps.carrier_credentials (carrier_id, environment)
  where company_id is null;

create unique index if not exists carrier_credentials_company_uniq
  on qvm_new_apps.carrier_credentials (carrier_id, company_id, environment)
  where company_id is not null;

comment on column qvm_new_apps.carrier_credentials.company_id is
  'Whose account this is. Null is the platform default, used when a company has none of its own.';

alter table qvm_new_apps.service_credentials
  add column if not exists company_id integer references qvm_new_apps.client_companies(company_id) on delete cascade;

-- The old primary key was the service name alone, which is exactly the assumption being removed.
alter table qvm_new_apps.service_credentials
  drop constraint if exists service_credentials_pkey;

create unique index if not exists service_credentials_platform_uniq
  on qvm_new_apps.service_credentials (service)
  where company_id is null;

create unique index if not exists service_credentials_company_uniq
  on qvm_new_apps.service_credentials (service, company_id)
  where company_id is not null;

comment on column qvm_new_apps.service_credentials.company_id is
  'Whose account this is. Null is the platform default, used when a company has none of its own.';

-- ── Resolution ─────────────────────────────────────────────────────────────────────────────────
-- One place that answers «which credential applies to this company», so the fallback rule is
-- written once instead of in every caller that reads a key.
create or replace function qvm_new_apps.service_credential_for(
  p_service    text,
  p_company_id integer default null)
returns table (service text, api_key text, extra jsonb, is_active boolean, company_id integer)
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select c.service, c.api_key, c.extra, c.is_active, c.company_id
    from qvm_new_apps.service_credentials c
   where c.service = p_service
     and (c.company_id = p_company_id or c.company_id is null)
   -- The company's own row first; the platform row is the fallback, never the winner.
   order by c.company_id nulls last
   limit 1;
$$;

create or replace function qvm_new_apps.carrier_credential_for(
  p_carrier_id  integer,
  p_company_id  integer default null,
  p_environment text default 'production')
returns table (credential_id bigint, api_base_url text, api_token text, environment text,
               webhook_secret text, is_active boolean, company_id integer)
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select c.credential_id, c.api_base_url, c.api_token, c.environment,
         c.webhook_secret, c.is_active, c.company_id
    from qvm_new_apps.carrier_credentials c
   where c.carrier_id = p_carrier_id
     and c.environment = p_environment
     and (c.company_id = p_company_id or c.company_id is null)
   order by c.company_id nulls last
   limit 1;
$$;

-- Neither is granted to authenticated: they return the key itself. Only the edge functions, which
-- run with the service role and never hand a token back to a browser, are meant to call them.
revoke all on function qvm_new_apps.service_credential_for(text, integer) from public;
revoke all on function qvm_new_apps.carrier_credential_for(integer, integer, text) from public;
grant execute on function qvm_new_apps.service_credential_for(text, integer),
                          qvm_new_apps.carrier_credential_for(integer, integer, text)
  to service_role;
