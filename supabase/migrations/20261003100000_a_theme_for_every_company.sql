-- A theme for every company.
--
-- The platform wore one look, written into the stylesheet: Qparts' navy and red, a white sidebar,
-- the Q mark. Now the look is a record. A theme names its colours — the brand, the sidebar, the
-- surfaces, the text — its font and its logos, and the Qparts Admin makes themes, previews them,
-- and assigns one to a company or several. A company with no theme of its own, including every
-- company created from now on, wears the default, which is today's look. The first theme beyond
-- it is Shihab's: a burgundy sidebar with coral accents, from the design handed over on
-- 2026-10-03.
--
-- The tokens, each a CSS colour the app reads at runtime:
--   primary, primaryLight      the brand colour and its lighter step (brand-navy)
--   accent, accentLight        the accent and its tint (brand-red)
--   tertiary, tertiaryLight    the third brand colour (brand-purple)
--   pageBg                     the page behind everything
--   sidebarBg, sidebarBorder   the sidebar
--   navText, navIcon           an item of the menu at rest
--   groupLabel                 the small section labels of the menu
--   activeBg, activeText       the item of the page that is open
--   marker                     the bar beside the open item
--   topbarBg                   the header
--   heroBg, heroText           the banner at the top of a dashboard
--   cardBg, cardBorder         a card
--   ink, muted                 body text and secondary text

CREATE TABLE IF NOT EXISTS qvm_new_apps.themes (
  theme_id         bigserial PRIMARY KEY,
  name             text NOT NULL,
  description      text,
  is_default       boolean NOT NULL DEFAULT false,
  font             text NOT NULL DEFAULT '''Inter'', sans-serif',
  tokens           jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- The logo on light surfaces (the header, a white sidebar, documents) and the one on dark
  -- surfaces (a coloured sidebar). Either a full URL or a path inside the attachments bucket.
  logo_url         text,
  logo_on_dark_url text,
  -- The name the app calls itself under this theme, beside the logo where the wordmark used to be.
  app_name         text,
  created_by       uuid DEFAULT auth.uid(),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_by       uuid,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  deleted_at       timestamptz
);
COMMENT ON TABLE qvm_new_apps.themes IS 'A look of the platform: colours, font and logos. One is the default; a company may be assigned another.';
-- Exactly one default among the live themes.
CREATE UNIQUE INDEX IF NOT EXISTS ux_themes_one_default ON qvm_new_apps.themes ((true)) WHERE is_default AND deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS qvm_new_apps.company_themes (
  company_id   integer PRIMARY KEY REFERENCES qvm_new_apps.list_data(list_data_id) ON DELETE CASCADE,
  theme_id     bigint NOT NULL REFERENCES qvm_new_apps.themes(theme_id) ON DELETE CASCADE,
  assigned_by  uuid DEFAULT auth.uid(),
  assigned_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE qvm_new_apps.company_themes IS 'The theme a company wears; a company with no row wears the default.';
CREATE INDEX IF NOT EXISTS ix_company_themes_theme ON qvm_new_apps.company_themes (theme_id);

-- Read and written through the functions below only.
ALTER TABLE qvm_new_apps.themes ENABLE ROW LEVEL SECURITY;
ALTER TABLE qvm_new_apps.company_themes ENABLE ROW LEVEL SECURITY;

-- The default: today's look, as the stylesheet had it.
INSERT INTO qvm_new_apps.themes (name, description, is_default, font, tokens, app_name)
SELECT 'QVM', 'The platform''s own look: navy and red on white.', true, '''Inter'', sans-serif',
       '{"primary":"#0D4151","primaryLight":"#1A5A6E","accent":"#E21A1A","accentLight":"#FEF2F2","tertiary":"#845C7B","tertiaryLight":"#9A7291",
         "pageBg":"#F8FAFC","sidebarBg":"#FFFFFF","sidebarBorder":"#E2E8F0","navText":"#475569","navIcon":"#64748B","groupLabel":"#94A3B8",
         "activeBg":"#F3F5F6","activeText":"#0D4151","marker":"#E21A1A","topbarBg":"#FFFFFF","heroBg":"#0D4151","heroText":"#FFFFFF",
         "cardBg":"#FFFFFF","cardBorder":"#E2E8F0","ink":"#0F172A","muted":"#64748B"}'::jsonb,
       'QVM Parts'
WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.themes WHERE is_default AND deleted_at IS NULL);

-- Shihab — Burgundy Sidebar, exactly as designed (theme 1b of the handed-over page).
INSERT INTO qvm_new_apps.themes (name, description, is_default, font, tokens, logo_url, logo_on_dark_url, app_name)
SELECT 'Shihab — Burgundy', 'قائمة جانبية عنابية + لمسات مرجانية · Burgundy #531A35 · Coral #FB6F3F · Coral Tint #943C3C · Light Coral #D6A694 · Warm White #F7F6F2',
       false, '''IBM Plex Sans'', ''IBM Plex Sans Arabic'', sans-serif',
       '{"primary":"#531A35","primaryLight":"#6A2B46","accent":"#FB6F3F","accentLight":"#F7EDE8","tertiary":"#943C3C","tertiaryLight":"#D6A694",
         "pageBg":"#F7F6F2","sidebarBg":"#531A35","sidebarBorder":"#64283F","navText":"#EFE4E8","navIcon":"#D6A694","groupLabel":"#C9A3AE",
         "activeBg":"#6A2B46","activeText":"#FFFFFF","marker":"#FB6F3F","topbarBg":"#FFFFFF","heroBg":"#531A35","heroText":"#F7F6F2",
         "cardBg":"#FFFFFF","cardBorder":"#ECE8E1","ink":"#22161B","muted":"#6E6460"}'::jsonb,
       'themes/shihab/logo-on-light.png', 'themes/shihab/logo-on-dark.png', 'Shihab'
WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.themes WHERE name = 'Shihab — Burgundy' AND deleted_at IS NULL);

-- A theme as the app reads it, with the companies that wear it.
CREATE OR REPLACE FUNCTION qvm_new_apps.theme_json(p_theme_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object(
           'theme_id', t.theme_id, 'name', t.name, 'description', t.description, 'is_default', t.is_default,
           'font', t.font, 'tokens', t.tokens, 'logo_url', t.logo_url, 'logo_on_dark_url', t.logo_on_dark_url,
           'app_name', t.app_name, 'created_at', t.created_at, 'updated_at', t.updated_at,
           'companies', COALESCE((
             SELECT jsonb_agg(jsonb_build_object('company_id', ct.company_id, 'company_name', ld.list_data) ORDER BY ld.list_data)
               FROM qvm_new_apps.company_themes ct
               JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ct.company_id
              WHERE ct.theme_id = t.theme_id), '[]'::jsonb))
    FROM qvm_new_apps.themes t
   WHERE t.theme_id = p_theme_id AND t.deleted_at IS NULL;
$function$;

-- Every live theme, the default first.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_themes()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(qvm_new_apps.theme_json(t.theme_id) ORDER BY t.is_default DESC, t.name), '[]'::jsonb)
    FROM qvm_new_apps.themes t WHERE t.deleted_at IS NULL;
$function$;

-- The theme the caller sees: their company's, or the default. Anyone — the login page wears it too.
CREATE OR REPLACE FUNCTION qvm_new_apps.my_theme()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT qvm_new_apps.theme_json(COALESCE(
           (SELECT ct.theme_id FROM qvm_new_apps.user_data ud
              JOIN qvm_new_apps.company_themes ct ON ct.company_id = ud.user_company
              JOIN qvm_new_apps.themes t ON t.theme_id = ct.theme_id AND t.deleted_at IS NULL
             WHERE ud.user_id = auth.uid() AND ud.deleted_at IS NULL),
           (SELECT t.theme_id FROM qvm_new_apps.themes t WHERE t.is_default AND t.deleted_at IS NULL LIMIT 1)));
$function$;

-- Every company and the theme it wears, for the assignment picker.
CREATE OR REPLACE FUNCTION qvm_new_apps.list_theme_companies()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin manages themes'; END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('company_id', d.list_data_id, 'company_name', d.list_data,
                                        'theme_id', ct.theme_id, 'theme_name', t.name) ORDER BY d.list_data)
      FROM qvm_new_apps.list_data d
      JOIN qvm_new_apps.lists l ON l.list_id = d.list_id AND l.list_name = 'client_name'
      LEFT JOIN qvm_new_apps.company_themes ct ON ct.company_id = d.list_data_id
      LEFT JOIN qvm_new_apps.themes t ON t.theme_id = ct.theme_id AND t.deleted_at IS NULL), '[]'::jsonb);
END $function$;

-- Creates or changes a theme. p_theme carries theme_id (null for a new one), name, description,
-- font, tokens, logo_url, logo_on_dark_url, app_name. Every token is a six-digit hex colour.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_save_theme(p_theme jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint := NULLIF(p_theme->>'theme_id', '')::bigint;
  v_tokens jsonb := COALESCE(p_theme->'tokens', '{}'::jsonb);
  v_bad text;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin manages themes'; END IF;
  IF COALESCE(btrim(p_theme->>'name'), '') = '' THEN RAISE EXCEPTION 'A theme needs a name'; END IF;
  IF jsonb_typeof(v_tokens) <> 'object' THEN RAISE EXCEPTION 'The colours must be an object of token → colour'; END IF;
  SELECT key INTO v_bad FROM jsonb_each_text(v_tokens) WHERE value !~ '^#[0-9A-Fa-f]{6}$' LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'The colour of % must be a six-digit hex value', v_bad; END IF;

  IF v_id IS NULL THEN
    INSERT INTO qvm_new_apps.themes (name, description, font, tokens, logo_url, logo_on_dark_url, app_name, created_by, updated_by)
    VALUES (btrim(p_theme->>'name'), NULLIF(btrim(COALESCE(p_theme->>'description', '')), ''),
            COALESCE(NULLIF(btrim(p_theme->>'font'), ''), '''Inter'', sans-serif'), v_tokens,
            NULLIF(btrim(COALESCE(p_theme->>'logo_url', '')), ''), NULLIF(btrim(COALESCE(p_theme->>'logo_on_dark_url', '')), ''),
            NULLIF(btrim(COALESCE(p_theme->>'app_name', '')), ''), auth.uid(), auth.uid())
    RETURNING theme_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.themes
       SET name = btrim(p_theme->>'name'),
           description = NULLIF(btrim(COALESCE(p_theme->>'description', '')), ''),
           font = COALESCE(NULLIF(btrim(p_theme->>'font'), ''), font),
           tokens = v_tokens,
           logo_url = NULLIF(btrim(COALESCE(p_theme->>'logo_url', '')), ''),
           logo_on_dark_url = NULLIF(btrim(COALESCE(p_theme->>'logo_on_dark_url', '')), ''),
           app_name = NULLIF(btrim(COALESCE(p_theme->>'app_name', '')), ''),
           updated_by = auth.uid(), updated_at = now()
     WHERE theme_id = v_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown theme'; END IF;
  END IF;
  RETURN qvm_new_apps.theme_json(v_id);
END $function$;

-- The default: what every company without a theme of its own wears.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_default_theme(p_theme_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin manages themes'; END IF;
  IF NOT EXISTS (SELECT 1 FROM qvm_new_apps.themes WHERE theme_id = p_theme_id AND deleted_at IS NULL) THEN RAISE EXCEPTION 'Unknown theme'; END IF;
  UPDATE qvm_new_apps.themes SET is_default = false, updated_at = now(), updated_by = auth.uid() WHERE is_default AND theme_id <> p_theme_id;
  UPDATE qvm_new_apps.themes SET is_default = true, updated_at = now(), updated_by = auth.uid() WHERE theme_id = p_theme_id;
  RETURN qvm_new_apps.theme_json(p_theme_id);
END $function$;

-- Removes a theme that is not the default; the companies that wore it fall back to the default.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_delete_theme(p_theme_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin manages themes'; END IF;
  IF EXISTS (SELECT 1 FROM qvm_new_apps.themes WHERE theme_id = p_theme_id AND is_default) THEN
    RAISE EXCEPTION 'The default theme cannot be removed; make another theme the default first';
  END IF;
  DELETE FROM qvm_new_apps.company_themes WHERE theme_id = p_theme_id;
  UPDATE qvm_new_apps.themes SET deleted_at = now(), updated_by = auth.uid() WHERE theme_id = p_theme_id AND deleted_at IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown theme'; END IF;
  RETURN jsonb_build_object('status', 'success');
END $function$;

-- Gives the companies named the theme; with no theme, they go back to the default.
CREATE OR REPLACE FUNCTION qvm_new_apps.admin_assign_theme(p_theme_id bigint, p_company_ids integer[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin manages themes'; END IF;
  IF p_theme_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM qvm_new_apps.themes WHERE theme_id = p_theme_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Unknown theme';
  END IF;
  DELETE FROM qvm_new_apps.company_themes WHERE company_id = ANY(COALESCE(p_company_ids, ARRAY[]::integer[]));
  IF p_theme_id IS NOT NULL THEN
    INSERT INTO qvm_new_apps.company_themes (company_id, theme_id, assigned_by)
    SELECT c, p_theme_id, auth.uid() FROM unnest(COALESCE(p_company_ids, ARRAY[]::integer[])) AS c;
  END IF;
  RETURN CASE WHEN p_theme_id IS NULL THEN jsonb_build_object('status', 'success') ELSE qvm_new_apps.theme_json(p_theme_id) END;
END $function$;

-- The app calls these without a schema.
CREATE OR REPLACE FUNCTION public.list_themes() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.list_themes() $function$;
CREATE OR REPLACE FUNCTION public.my_theme() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.my_theme() $function$;
CREATE OR REPLACE FUNCTION public.list_theme_companies() RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.list_theme_companies() $function$;
CREATE OR REPLACE FUNCTION public.admin_save_theme(p_theme jsonb) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.admin_save_theme(p_theme) $function$;
CREATE OR REPLACE FUNCTION public.admin_set_default_theme(p_theme_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.admin_set_default_theme(p_theme_id) $function$;
CREATE OR REPLACE FUNCTION public.admin_delete_theme(p_theme_id bigint) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.admin_delete_theme(p_theme_id) $function$;
CREATE OR REPLACE FUNCTION public.admin_assign_theme(p_theme_id bigint, p_company_ids integer[]) RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'qvm_new_apps', 'public'
AS $function$ SELECT qvm_new_apps.admin_assign_theme(p_theme_id, p_company_ids) $function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.my_theme(), public.my_theme() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_themes(), public.list_themes() TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.list_theme_companies(), public.list_theme_companies() TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_save_theme(jsonb), public.admin_save_theme(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_set_default_theme(bigint), public.admin_set_default_theme(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_delete_theme(bigint), public.admin_delete_theme(bigint) TO authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.admin_assign_theme(bigint, integer[]), public.admin_assign_theme(bigint, integer[]) TO authenticated;
REVOKE ALL ON FUNCTION qvm_new_apps.theme_json(bigint) FROM PUBLIC, anon, authenticated;
