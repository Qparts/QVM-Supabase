-- A theme dresses its login page.
--
-- The sign-in screen was pinned to one look. It now belongs to the theme like every other page:
-- a theme carries the login page's photograph, headline, highlighted word, tagline, badge and
-- security line, the editor previews and edits them, and the page reads them from the theme the
-- host (or the account) wears. The default theme therefore dresses the platform's own domain and
-- every company without a theme of its own. A theme without these settings falls back to the
-- platform's words and to its banner colours instead of a photograph.

ALTER TABLE qvm_new_apps.themes ADD COLUMN IF NOT EXISTS login jsonb NOT NULL DEFAULT '{}'::jsonb;
COMMENT ON COLUMN qvm_new_apps.themes.login IS 'The login page: photo_url, headline, accent_word, tagline, badge, security_title, security_text. Empty keys fall back to the platform''s words.';

CREATE OR REPLACE FUNCTION qvm_new_apps.theme_json(p_theme_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
  SELECT jsonb_build_object(
           'theme_id', t.theme_id, 'name', t.name, 'description', t.description, 'is_default', t.is_default,
           'font', t.font, 'tokens', t.tokens, 'hero_style', t.hero_style,
           'logo_url', t.logo_url, 'logo_on_dark_url', t.logo_on_dark_url,
           'app_name', t.app_name, 'login', COALESCE(t.login, '{}'::jsonb), 'created_at', t.created_at, 'updated_at', t.updated_at,
           'companies', COALESCE((
             SELECT jsonb_agg(jsonb_build_object('company_id', ct.company_id, 'company_name', ld.list_data) ORDER BY ld.list_data)
               FROM qvm_new_apps.company_themes ct
               JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ct.company_id
              WHERE ct.theme_id = t.theme_id), '[]'::jsonb))
    FROM qvm_new_apps.themes t
   WHERE t.theme_id = p_theme_id AND t.deleted_at IS NULL;
$function$;

-- The login settings, kept to the known keys, each a trimmed string of sane length; blanks dropped.
CREATE OR REPLACE FUNCTION qvm_new_apps.clean_theme_login(p_login jsonb)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
  SELECT COALESCE((
    SELECT jsonb_object_agg(k, left(btrim(v), CASE WHEN k = 'photo_url' THEN 600 ELSE 240 END))
      FROM jsonb_each_text(CASE WHEN jsonb_typeof(p_login) = 'object' THEN p_login ELSE '{}'::jsonb END) e(k, v)
     WHERE k IN ('photo_url', 'headline', 'accent_word', 'tagline', 'badge', 'security_title', 'security_text')
       AND btrim(COALESCE(v, '')) <> ''), '{}'::jsonb);
$function$;

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_save_theme(p_theme jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_id bigint := NULLIF(p_theme->>'theme_id', '')::bigint;
  v_tokens jsonb := COALESCE(p_theme->'tokens', '{}'::jsonb);
  v_style text := COALESCE(NULLIF(btrim(p_theme->>'hero_style'), ''), 'gradient');
  v_login jsonb := qvm_new_apps.clean_theme_login(p_theme->'login');
  v_bad text;
BEGIN
  IF NOT qvm_new_apps.is_qparts_admin(auth.uid()) THEN RAISE EXCEPTION 'Only the Qparts Admin manages themes'; END IF;
  IF COALESCE(btrim(p_theme->>'name'), '') = '' THEN RAISE EXCEPTION 'A theme needs a name'; END IF;
  IF jsonb_typeof(v_tokens) <> 'object' THEN RAISE EXCEPTION 'The colours must be an object of token → colour'; END IF;
  SELECT key INTO v_bad FROM jsonb_each_text(v_tokens) WHERE value !~ '^#[0-9A-Fa-f]{6}$' LIMIT 1;
  IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'The colour of % must be a six-digit hex value', v_bad; END IF;
  IF v_style NOT IN ('gradient', 'solid', 'ring', 'glow', 'stripes', 'dots', 'edge', 'mesh') THEN
    RAISE EXCEPTION 'Unknown header style %', v_style;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO qvm_new_apps.themes (name, description, font, tokens, hero_style, logo_url, logo_on_dark_url, app_name, login, created_by, updated_by)
    VALUES (btrim(p_theme->>'name'), NULLIF(btrim(COALESCE(p_theme->>'description', '')), ''),
            COALESCE(NULLIF(btrim(p_theme->>'font'), ''), '''Inter'', sans-serif'), v_tokens, v_style,
            NULLIF(btrim(COALESCE(p_theme->>'logo_url', '')), ''), NULLIF(btrim(COALESCE(p_theme->>'logo_on_dark_url', '')), ''),
            NULLIF(btrim(COALESCE(p_theme->>'app_name', '')), ''), v_login, auth.uid(), auth.uid())
    RETURNING theme_id INTO v_id;
  ELSE
    UPDATE qvm_new_apps.themes
       SET name = btrim(p_theme->>'name'),
           description = NULLIF(btrim(COALESCE(p_theme->>'description', '')), ''),
           font = COALESCE(NULLIF(btrim(p_theme->>'font'), ''), font),
           tokens = v_tokens,
           hero_style = v_style,
           logo_url = NULLIF(btrim(COALESCE(p_theme->>'logo_url', '')), ''),
           logo_on_dark_url = NULLIF(btrim(COALESCE(p_theme->>'logo_on_dark_url', '')), ''),
           app_name = NULLIF(btrim(COALESCE(p_theme->>'app_name', '')), ''),
           -- Left out of the payload, the login settings stay; sent, they are replaced.
           login = CASE WHEN p_theme ? 'login' THEN v_login ELSE login END,
           updated_by = auth.uid(), updated_at = now()
     WHERE theme_id = v_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown theme'; END IF;
  END IF;
  RETURN qvm_new_apps.theme_json(v_id);
END $function$;
