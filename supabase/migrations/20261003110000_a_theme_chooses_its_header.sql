-- A theme chooses its header.
--
-- The banner at the top of each page was a gradient written into every page — navy fading to
-- teal — so a theme could only recolour its first stop, and Shihab's header came out burgundy
-- fading to teal where the design had a flat burgundy block with a coral ring at its corner.
-- Now a theme names its header style, one of a set the app knows how to draw from the theme's own
-- colours (a flat block, the gradient, the signature ring, a corner glow, fine stripes, a dot
-- grid, an accent edge, an aurora mesh), and a second banner colour for the gradient's far end.
-- Today's look keeps the gradient; Shihab gets its ring.

ALTER TABLE qvm_new_apps.themes ADD COLUMN IF NOT EXISTS hero_style text NOT NULL DEFAULT 'gradient';
ALTER TABLE qvm_new_apps.themes DROP CONSTRAINT IF EXISTS themes_hero_style_chk;
ALTER TABLE qvm_new_apps.themes ADD CONSTRAINT themes_hero_style_chk
  CHECK (hero_style IN ('gradient', 'solid', 'ring', 'glow', 'stripes', 'dots', 'edge', 'mesh'));
COMMENT ON COLUMN qvm_new_apps.themes.hero_style IS 'How the page banners are drawn from the theme''s colours: gradient | solid | ring | glow | stripes | dots | edge | mesh.';

-- The gradient's far end: today's teal for the default, a lighter burgundy for Shihab.
UPDATE qvm_new_apps.themes SET tokens = tokens || '{"heroBg2":"#0F766E"}'::jsonb WHERE is_default AND NOT (tokens ? 'heroBg2');
UPDATE qvm_new_apps.themes SET tokens = tokens || '{"heroBg2":"#6A2B46"}'::jsonb, hero_style = 'ring'
 WHERE name = 'Shihab — Burgundy' AND deleted_at IS NULL AND NOT (tokens ? 'heroBg2');
UPDATE qvm_new_apps.themes SET tokens = tokens || jsonb_build_object('heroBg2', COALESCE(tokens->>'primaryLight', tokens->>'heroBg', '#1A5A6E'))
 WHERE NOT (tokens ? 'heroBg2');

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
           'app_name', t.app_name, 'created_at', t.created_at, 'updated_at', t.updated_at,
           'companies', COALESCE((
             SELECT jsonb_agg(jsonb_build_object('company_id', ct.company_id, 'company_name', ld.list_data) ORDER BY ld.list_data)
               FROM qvm_new_apps.company_themes ct
               JOIN qvm_new_apps.list_data ld ON ld.list_data_id = ct.company_id
              WHERE ct.theme_id = t.theme_id), '[]'::jsonb))
    FROM qvm_new_apps.themes t
   WHERE t.theme_id = p_theme_id AND t.deleted_at IS NULL;
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
    INSERT INTO qvm_new_apps.themes (name, description, font, tokens, hero_style, logo_url, logo_on_dark_url, app_name, created_by, updated_by)
    VALUES (btrim(p_theme->>'name'), NULLIF(btrim(COALESCE(p_theme->>'description', '')), ''),
            COALESCE(NULLIF(btrim(p_theme->>'font'), ''), '''Inter'', sans-serif'), v_tokens, v_style,
            NULLIF(btrim(COALESCE(p_theme->>'logo_url', '')), ''), NULLIF(btrim(COALESCE(p_theme->>'logo_on_dark_url', '')), ''),
            NULLIF(btrim(COALESCE(p_theme->>'app_name', '')), ''), auth.uid(), auth.uid())
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
           updated_by = auth.uid(), updated_at = now()
     WHERE theme_id = v_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown theme'; END IF;
  END IF;
  RETURN qvm_new_apps.theme_json(v_id);
END $function$;
