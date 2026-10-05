-- A company has a subdomain.
--
-- Each client company can be reached at its own host under the platform's domain —
-- shihab.qvm-pro.space — and that host wears the company's theme from the first paint, before
-- anyone signs in. The host is a record, not a convention: the browser asks the database which
-- company a hostname belongs to, and the database answers from company_domains. The subdomain is
-- branding and a tenant hint, never an access grant; who may see what is still decided by the
-- account after sign-in.
--
--   * platform_settings holds the base domain (qvm-pro.space on this environment), so the same
--     code serves another domain in production by changing one row.
--   * company_domains: one row per host, with the company, the subdomain, the provisioning state
--     on Netlify (pending → active | failed, or disabled) and what went wrong when it did. The
--     theme a host wears is the company's theme (company_themes); there is no second place to set
--     it, so the login page and the app after sign-in always agree.
--   * resolve_host(host) is the one thing the browser asks before sign-in: anonymous, read-only,
--     returns the company and its theme for a known host and nothing for any other hostname.
--   * The Qparts Admin sets, retries and disables a company's subdomain; the provisioning edge
--     function (provision_company_domain) talks to Netlify and records the outcome through a
--     service-role-only function.

-- ───────────────────────────── settings ─────────────────────────────

CREATE TABLE IF NOT EXISTS qvm_new_apps.platform_settings (
  key        text PRIMARY KEY,
  value      text,
  updated_by uuid,
  updated_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE qvm_new_apps.platform_settings IS 'Platform-wide settings a deployment differs by: the base domain the company subdomains hang under.';
ALTER TABLE qvm_new_apps.platform_settings ENABLE ROW LEVEL SECURITY;
INSERT INTO qvm_new_apps.platform_settings (key, value) VALUES ('base_domain', 'qvm-pro.space') ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION qvm_new_apps.platform_setting(p_key text)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT value FROM qvm_new_apps.platform_settings WHERE key = p_key $function$;

-- ───────────────────────────── the domains ─────────────────────────────

CREATE TABLE IF NOT EXISTS qvm_new_apps.company_domains (
  domain_id       bigserial PRIMARY KEY,
  company_id      integer NOT NULL REFERENCES qvm_new_apps.list_data(list_data_id),
  -- The label under the base domain: lowercase letters, digits and hyphens, 2–40 characters.
  subdomain       text NOT NULL,
  -- The full host as it is served, fixed when the row is made: subdomain + '.' + base domain.
  host            text NOT NULL UNIQUE,
  -- Where Netlify stands with it. pending: recorded here, not yet on the site. active: the site
  -- answers for it. failed: Netlify refused; last_error says why. disabled: taken off the site.
  status          text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'active', 'failed', 'disabled')),
  is_primary      boolean NOT NULL DEFAULT true,
  provisioned_at  timestamptz,
  last_attempt_at timestamptz,
  last_error      text,
  created_by      uuid DEFAULT auth.uid(),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_by      uuid,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  disabled_at     timestamptz,
  CONSTRAINT company_domains_subdomain_shape CHECK (subdomain ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$')
);
COMMENT ON TABLE qvm_new_apps.company_domains IS 'The hosts a company is served at under the platform domain, and where Netlify stands with each.';
-- One live primary host per company; a disabled row keeps its history and frees the name.
CREATE UNIQUE INDEX IF NOT EXISTS ux_company_domains_primary ON qvm_new_apps.company_domains (company_id) WHERE is_primary AND status <> 'disabled';
CREATE UNIQUE INDEX IF NOT EXISTS ux_company_domains_live_subdomain ON qvm_new_apps.company_domains (subdomain) WHERE status <> 'disabled';
CREATE INDEX IF NOT EXISTS ix_company_domains_company ON qvm_new_apps.company_domains (company_id);
ALTER TABLE qvm_new_apps.company_domains ENABLE ROW LEVEL SECURITY;

-- Names the platform keeps for itself, whatever a company is called.
CREATE OR REPLACE FUNCTION qvm_new_apps.reserved_subdomains()
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$ SELECT ARRAY['www', 'api', 'app', 'admin', 'mail', 'smtp', 'imap', 'ftp', 'dev', 'test', 'staging', 'qvm', 'qparts', 'portal', 'login', 'auth', 'static', 'cdn', 'status', 'support', 'help', 'docs', 'mcp'] $function$;

-- A company name, as a subdomain: lower-cased, spaces and punctuation to hyphens, nothing but
-- a–z, 0–9 and hyphens left. An Arabic-only name gives an empty string, and the form asks.
CREATE OR REPLACE FUNCTION qvm_new_apps.normalize_subdomain(p_text text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT left(btrim(regexp_replace(regexp_replace(lower(COALESCE(p_text, '')), '[^a-z0-9]+', '-', 'g'), '-{2,}', '-', 'g'), '-'), 40)
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.company_domain_json(p_domain_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object(
           'domain_id', d.domain_id, 'company_id', d.company_id, 'company_name', ld.list_data,
           'subdomain', d.subdomain, 'host', d.host, 'status', d.status, 'is_primary', d.is_primary,
           'provisioned_at', d.provisioned_at, 'last_attempt_at', d.last_attempt_at, 'last_error', d.last_error,
           'theme_id', ct.theme_id, 'theme_name', t.name,
           'created_at', d.created_at, 'updated_at', d.updated_at, 'disabled_at', d.disabled_at)
    FROM qvm_new_apps.company_domains d
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = d.company_id
    LEFT JOIN qvm_new_apps.company_themes ct ON ct.company_id = d.company_id
    LEFT JOIN qvm_new_apps.themes t ON t.theme_id = ct.theme_id AND t.deleted_at IS NULL
   WHERE d.domain_id = p_domain_id;
$function$;
REVOKE ALL ON FUNCTION qvm_new_apps.company_domain_json(bigint) FROM PUBLIC, anon, authenticated;

-- ───────────────────────────── the Qparts Admin's functions ─────────────────────────────

-- Gives a company its subdomain, or changes it. A changed name retires the old host (disabled)
-- and makes a new pending one, so the provisioning function has one thing to add and one to
-- remove. The same name again only returns the row.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_company_domain(p_company_id integer, p_subdomain text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_sub text := qvm_new_apps.normalize_subdomain(p_subdomain);
  v_base text := COALESCE(qvm_new_apps.platform_setting('base_domain'), 'qvm-pro.space');
  v_host text;
  v_current qvm_new_apps.company_domains%ROWTYPE;
  v_id bigint;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin sets company domains'; END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.list_data ld JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id AND l.list_name = 'client_name' WHERE ld.list_data_id = p_company_id) THEN
    RAISE EXCEPTION 'Unknown company';
  END IF;
  IF v_sub !~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' THEN
    RAISE EXCEPTION 'A subdomain is 2–40 lowercase letters, digits or hyphens, and cannot start or end with a hyphen';
  END IF;
  IF v_sub = ANY(qvm_new_apps.reserved_subdomains()) THEN RAISE EXCEPTION 'The name % is reserved by the platform', v_sub; END IF;
  v_host := v_sub || '.' || v_base;

  SELECT * INTO v_current FROM qvm_new_apps.company_domains WHERE company_id = p_company_id AND is_primary AND status <> 'disabled';
  IF FOUND AND v_current.subdomain = v_sub THEN
    RETURN qvm_new_apps.company_domain_json(v_current.domain_id);
  END IF;
  IF EXISTS (SELECT 1 FROM qvm_new_apps.company_domains WHERE subdomain = v_sub AND status <> 'disabled' AND company_id <> p_company_id) THEN
    RAISE EXCEPTION 'The subdomain % is already taken', v_sub;
  END IF;

  IF FOUND THEN
    UPDATE qvm_new_apps.company_domains
       SET status = 'disabled', disabled_at = now(), updated_by = auth.uid(), updated_at = now()
     WHERE domain_id = v_current.domain_id;
  END IF;

  INSERT INTO qvm_new_apps.company_domains (company_id, subdomain, host, status, is_primary, created_by, updated_by)
  VALUES (p_company_id, v_sub, v_host, 'pending', true, auth.uid(), auth.uid())
  ON CONFLICT (host) DO UPDATE
    SET status = 'pending', is_primary = true, disabled_at = NULL, last_error = NULL, updated_by = auth.uid(), updated_at = now()
  RETURNING domain_id INTO v_id;
  RETURN qvm_new_apps.company_domain_json(v_id);
END $function$;

-- Takes a host off: the row stays as history, the name is free again, and the provisioning
-- function removes the alias from the site.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_disable_company_domain(p_domain_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin sets company domains'; END IF;
  UPDATE qvm_new_apps.company_domains
     SET status = 'disabled', disabled_at = now(), updated_by = auth.uid(), updated_at = now()
   WHERE domain_id = p_domain_id AND status <> 'disabled';
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown domain, or already disabled'; END IF;
  RETURN qvm_new_apps.company_domain_json(p_domain_id);
END $function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.list_company_domains()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin sets company domains'; END IF;
  RETURN jsonb_build_object(
    'base_domain', COALESCE(qvm_new_apps.platform_setting('base_domain'), 'qvm-pro.space'),
    'reserved', to_jsonb(qvm_new_apps.reserved_subdomains()),
    'domains', COALESCE((SELECT jsonb_agg(qvm_new_apps.company_domain_json(d.domain_id) ORDER BY (d.status = 'disabled'), d.host)
                           FROM qvm_new_apps.company_domains d), '[]'::jsonb),
    -- Every client company, with its live host if it has one: the panel lists the ones without too.
    'companies', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('company_id', ld.list_data_id, 'company_name', ld.list_data,
                                          'suggested', qvm_new_apps.normalize_subdomain(COALESCE(cd.name, ld.list_data)),
                                          'domain_id', d.domain_id, 'host', d.host, 'status', d.status,
                                          'theme_id', ct.theme_id, 'theme_name', t.name) ORDER BY ld.list_data)
        FROM qvm_new_apps.list_data ld
        JOIN qvm_new_apps.lists l ON l.list_id = ld.list_id AND l.list_name = 'client_name'
        LEFT JOIN LATERAL (SELECT c.name FROM qvm_new_apps.client_companies_descriptions c WHERE c.company_id = ld.list_data_id AND c.name ~ '[A-Za-z]' ORDER BY c.language_id LIMIT 1) cd ON true
        LEFT JOIN qvm_new_apps.company_domains d ON d.company_id = ld.list_data_id AND d.is_primary AND d.status <> 'disabled'
        LEFT JOIN qvm_new_apps.company_themes ct ON ct.company_id = ld.list_data_id
        LEFT JOIN qvm_new_apps.themes t ON t.theme_id = ct.theme_id AND t.deleted_at IS NULL), '[]'::jsonb));
END $function$;

-- ───────────────────────────── the provisioning function's two calls ─────────────────────────────

-- What the edge function needs to act: the row, and the site's base domain. Service role only.
CREATE OR REPLACE FUNCTION qvm_new_apps.company_domain_for_provisioning(p_domain_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' AND current_user NOT IN ('postgres', 'service_role') THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  RETURN qvm_new_apps.company_domain_json(p_domain_id) || jsonb_build_object('base_domain', COALESCE(qvm_new_apps.platform_setting('base_domain'), 'qvm-pro.space'));
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.company_domain_for_provisioning(bigint) FROM PUBLIC, anon, authenticated;

-- The outcome, written by the edge function after talking to Netlify. Service role only.
CREATE OR REPLACE FUNCTION qvm_new_apps.mark_company_domain(p_domain_id bigint, p_status text, p_error text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF current_setting('request.jwt.claim.role', true) IS DISTINCT FROM 'service_role' AND current_user NOT IN ('postgres', 'service_role') THEN
    RAISE EXCEPTION 'Not allowed';
  END IF;
  IF p_status NOT IN ('active', 'failed', 'disabled', 'pending') THEN RAISE EXCEPTION 'Unknown status %', p_status; END IF;
  UPDATE qvm_new_apps.company_domains
     SET status = p_status,
         provisioned_at = CASE WHEN p_status = 'active' THEN now() ELSE provisioned_at END,
         last_attempt_at = now(),
         last_error = CASE WHEN p_status = 'failed' THEN left(p_error, 1000) ELSE NULL END,
         updated_at = now()
   WHERE domain_id = p_domain_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown domain'; END IF;
  RETURN qvm_new_apps.company_domain_json(p_domain_id);
END $function$;
REVOKE ALL ON FUNCTION qvm_new_apps.mark_company_domain(bigint, text, text) FROM PUBLIC, anon, authenticated;

-- ───────────────────────────── what the browser asks before sign-in ─────────────────────────────

-- The company behind a hostname, and the theme it wears. Anonymous and read-only: it gives away a
-- company's name and colours, which its own login page shows anyway, and nothing else. An unknown
-- host, the base domain itself, or a disabled host answers NULL, and the browser wears the default.
CREATE OR REPLACE FUNCTION qvm_new_apps.resolve_host(p_host text)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object(
           'company_id', d.company_id, 'company_name', ld.list_data, 'subdomain', d.subdomain, 'host', d.host, 'status', d.status,
           'theme', qvm_new_apps.theme_json(COALESCE(
             (SELECT ct.theme_id FROM qvm_new_apps.company_themes ct JOIN qvm_new_apps.themes t ON t.theme_id = ct.theme_id AND t.deleted_at IS NULL WHERE ct.company_id = d.company_id),
             (SELECT t.theme_id FROM qvm_new_apps.themes t WHERE t.is_default AND t.deleted_at IS NULL LIMIT 1))))
    FROM qvm_new_apps.company_domains d
    JOIN qvm_new_apps.list_data ld ON ld.list_data_id = d.company_id
   WHERE d.host = lower(btrim(COALESCE(p_host, ''))) AND d.status IN ('pending', 'active')
   LIMIT 1;
$function$;

-- The signed-in user's own company host, if it has one: the app sends a user who signed in on
-- another company's host back to their own.
CREATE OR REPLACE FUNCTION qvm_new_apps.my_company_host()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object('company_id', d.company_id, 'host', d.host, 'status', d.status)
    FROM qvm_new_apps.user_data ud
    JOIN qvm_new_apps.company_domains d ON d.company_id = ud.user_company AND d.is_primary AND d.status IN ('pending', 'active')
   WHERE ud.user_id = auth.uid() AND ud.deleted_at IS NULL
   LIMIT 1;
$function$;

-- ───────────────────────────── the app calls these without a schema ─────────────────────────────

CREATE OR REPLACE FUNCTION public.admin_set_company_domain(p_company_id integer, p_subdomain text) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.admin_set_company_domain(p_company_id, p_subdomain) $function$;
CREATE OR REPLACE FUNCTION public.admin_disable_company_domain(p_domain_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.admin_disable_company_domain(p_domain_id) $function$;
CREATE OR REPLACE FUNCTION public.list_company_domains() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.list_company_domains() $function$;
CREATE OR REPLACE FUNCTION public.resolve_host(p_host text) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.resolve_host(p_host) $function$;
CREATE OR REPLACE FUNCTION public.my_company_host() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.my_company_host() $function$;
CREATE OR REPLACE FUNCTION public.company_domain_for_provisioning(p_domain_id bigint) RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.company_domain_for_provisioning(p_domain_id) $function$;
CREATE OR REPLACE FUNCTION public.mark_company_domain(p_domain_id bigint, p_status text, p_error text DEFAULT NULL) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.mark_company_domain(p_domain_id, p_status, p_error) $function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_set_company_domain(integer, text), public.admin_set_company_domain(integer, text),
                          qvm_new_apps.admin_disable_company_domain(bigint), public.admin_disable_company_domain(bigint),
                          qvm_new_apps.list_company_domains(), public.list_company_domains(),
                          qvm_new_apps.my_company_host(), public.my_company_host() TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.resolve_host(text), public.resolve_host(text), qvm_new_apps.normalize_subdomain(text) TO anon, authenticated;
REVOKE ALL ON FUNCTION public.company_domain_for_provisioning(bigint), public.mark_company_domain(bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.company_domain_for_provisioning(bigint), qvm_new_apps.company_domain_for_provisioning(bigint),
                          public.mark_company_domain(bigint, text, text), qvm_new_apps.mark_company_domain(bigint, text, text) TO service_role;
