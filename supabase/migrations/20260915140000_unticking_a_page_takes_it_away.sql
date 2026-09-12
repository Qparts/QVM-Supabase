-- Unticking a page has to take it away.
--
-- Editing a role's permissions changed nothing, and the reason was two rules I wrote in the same
-- migration that cannot both hold:
--
--   saving  — a cell with nothing ticked is deleted, "because an absent decision and an emptied one
--             should mean the same thing"
--   reading — no row means nobody decided, so the page behaves as before, which is allowed
--
-- Put together they make revocation impossible. Untick view, save, and the row is deleted; the
-- missing row then reads as "no decision" and the page stays open. Every other edit worked, which
-- is what made it look like nothing at all was being saved.
--
-- An all-false row is the denial. It is stored. Getting back to "nobody decided" is what the reset
-- button is for — that is a separate act, and it was already the only thing that deleted rows.

CREATE OR REPLACE FUNCTION qvm_new_apps.admin_set_company_permissions(
  p_company_id integer,
  p_cells      jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'qvm_new_apps', 'public' AS $$
DECLARE v_uid uuid := auth.uid(); v_count int;
BEGIN
  IF NOT qvm_new_apps.can_admin_company(p_company_id) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Access denied: this company is not yours to administer');
  END IF;
  IF jsonb_typeof(p_cells) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Expected a list of cells');
  END IF;

  -- The role is still checked: it is a real thing with an id, and a company may only set rules for
  -- the roles it assigns. The page is not — it is the sidebar's own name for a screen, and a name
  -- that matches nothing is a row nothing reads.
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_cells) c
     WHERE NOT EXISTS (SELECT 1 FROM qvm_new_apps.permission_roles pr
                        WHERE pr.role_id = (c->>'role_id')::int AND pr.is_assignable)
        OR btrim(COALESCE(c->>'nav_id', '')) = ''
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'That role cannot be given permissions');
  END IF;

  INSERT INTO qvm_new_apps.company_role_permissions
    (company_id, role_id, nav_id, can_view, can_create, can_update, can_delete, updated_by, updated_at)
  SELECT p_company_id,
         (c->>'role_id')::int,
         btrim(c->>'nav_id'),
         COALESCE((c->>'view')::boolean, false),
         -- An action on a page nobody may open is not a permission, it is a contradiction.
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'create')::boolean, false),
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'update')::boolean, false),
         COALESCE((c->>'view')::boolean, false) AND COALESCE((c->>'delete')::boolean, false),
         v_uid, now()
  FROM jsonb_array_elements(p_cells) c
  ON CONFLICT (company_id, role_id, nav_id) DO UPDATE
    SET can_view = EXCLUDED.can_view, can_create = EXCLUDED.can_create,
        can_update = EXCLUDED.can_update, can_delete = EXCLUDED.can_delete,
        updated_by = EXCLUDED.updated_by, updated_at = now();

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('saved', v_count));
END $$;;
