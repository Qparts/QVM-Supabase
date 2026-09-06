-- A local record of the project's Supabase branches.
--
-- Branches are account-level: nothing about QVM/dev, QVM/test or QVM/main exists in Postgres, and
-- the only source of truth is the Management API, which needs a personal access token that no
-- ordinary caller should hold. So the list-branches edge function fetches them with that token and
-- hands the payload here, and everything else reads this table instead — a report, a dashboard or
-- an RPC can then answer "which branch is this and what git ref does it track" with plain SQL.
--
-- Two functions, deliberately split by who may call them:
--   sync_supabase_branches  writes, and is service_role only — it is the edge function's endpoint
--   list_supabase_branches  reads, and is open to internal users
--
-- The write side cannot gate on is_internal_user(): the edge function calls it with the service
-- role key, where auth.uid() is NULL. The caller is already checked in the edge function itself,
-- and the grants below are what stop anyone else reaching it.

CREATE TABLE IF NOT EXISTS qvm_new_apps.supabase_branches (
  branch_id          text PRIMARY KEY,           -- the Management API's own id for the branch
  parent_project_ref text NOT NULL,
  project_ref        text,
  name               text,
  git_branch         text,                       -- the git ref this branch deploys from
  is_default         boolean NOT NULL DEFAULT false,
  persistent         boolean NOT NULL DEFAULT false,
  status             text,
  pr_number          integer,
  branch_created_at  timestamptz,                -- as reported by the API, not by us
  branch_updated_at  timestamptz,
  synced_at          timestamptz NOT NULL DEFAULT now(),
  raw                jsonb                       -- the untouched object, so a new API field is never lost
);

CREATE INDEX IF NOT EXISTS supabase_branches_parent_idx
  ON qvm_new_apps.supabase_branches (parent_project_ref);

COMMENT ON TABLE qvm_new_apps.supabase_branches IS
  'Snapshot of the Supabase branches for a project, refreshed by the list-branches edge function.
   Never authoritative — the Management API is. synced_at says how stale a row is.';

-- Write side ------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.sync_supabase_branches(
  p_parent_ref text,
  p_branches jsonb
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
DECLARE
  v_seen text[];
  v_removed int;
BEGIN
  IF p_parent_ref IS NULL OR trim(p_parent_ref) = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'parent_project_ref is required');
  END IF;
  IF p_branches IS NULL OR jsonb_typeof(p_branches) <> 'array' THEN
    RETURN jsonb_build_object('success', false, 'error', 'p_branches must be a JSON array');
  END IF;

  INSERT INTO qvm_new_apps.supabase_branches AS sb (
    branch_id, parent_project_ref, project_ref, name, git_branch,
    is_default, persistent, status, pr_number,
    branch_created_at, branch_updated_at, synced_at, raw
  )
  SELECT
    COALESCE(e->>'id', e->>'project_ref'),
    p_parent_ref,
    e->>'project_ref',
    e->>'name',
    e->>'git_branch',
    COALESCE((e->>'is_default')::boolean, false),
    COALESCE((e->>'persistent')::boolean, false),
    e->>'status',
    NULLIF(e->>'pr_number', '')::int,
    NULLIF(e->>'created_at', '')::timestamptz,
    NULLIF(e->>'updated_at', '')::timestamptz,
    now(),
    e
  FROM jsonb_array_elements(p_branches) e
  WHERE COALESCE(e->>'id', e->>'project_ref') IS NOT NULL
  ON CONFLICT (branch_id) DO UPDATE SET
    parent_project_ref = EXCLUDED.parent_project_ref,
    project_ref        = EXCLUDED.project_ref,
    name               = EXCLUDED.name,
    git_branch         = EXCLUDED.git_branch,
    is_default         = EXCLUDED.is_default,
    persistent         = EXCLUDED.persistent,
    status             = EXCLUDED.status,
    pr_number          = EXCLUDED.pr_number,
    branch_created_at  = EXCLUDED.branch_created_at,
    branch_updated_at  = EXCLUDED.branch_updated_at,
    synced_at          = now(),
    raw                = EXCLUDED.raw;

  SELECT array_agg(COALESCE(e->>'id', e->>'project_ref'))
    INTO v_seen
  FROM jsonb_array_elements(p_branches) e;

  -- A branch deleted upstream should stop being reported here. Scoped to this parent, so syncing
  -- one project never disturbs another's rows.
  DELETE FROM qvm_new_apps.supabase_branches
  WHERE parent_project_ref = p_parent_ref
    AND NOT (branch_id = ANY(COALESCE(v_seen, ARRAY[]::text[])));
  GET DIAGNOSTICS v_removed = ROW_COUNT;

  RETURN jsonb_build_object(
    'success', true,
    'parent_project_ref', p_parent_ref,
    'synced', COALESCE(array_length(v_seen, 1), 0),
    'removed', v_removed,
    'branches', COALESCE((
      SELECT jsonb_agg(to_jsonb(b) - 'raw' ORDER BY b.is_default DESC, b.name)
      FROM qvm_new_apps.supabase_branches b
      WHERE b.parent_project_ref = p_parent_ref
    ), '[]'::jsonb)
  );
END;
$function$;

REVOKE ALL ON FUNCTION qvm_new_apps.sync_supabase_branches(text, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION qvm_new_apps.sync_supabase_branches(text, jsonb) TO service_role;

-- Read side -------------------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION qvm_new_apps.list_supabase_branches(p_parent_ref text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'qvm_new_apps', 'public'
AS $function$
BEGIN
  IF NOT qvm_new_apps.is_internal_user() THEN
    RETURN jsonb_build_object('status', false, 'message', 'Access denied: Internal users only', 'data', '[]'::jsonb);
  END IF;

  RETURN jsonb_build_object(
    'status', true,
    'message', 'OK',
    'data', COALESCE((
      SELECT jsonb_agg(to_jsonb(b) - 'raw' ORDER BY b.is_default DESC, b.name)
      FROM qvm_new_apps.supabase_branches b
      WHERE p_parent_ref IS NULL OR b.parent_project_ref = p_parent_ref
    ), '[]'::jsonb)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION qvm_new_apps.list_supabase_branches(text) TO authenticated;

-- public wrapper: supabase.rpc() with no schema resolves against `public`.
CREATE OR REPLACE FUNCTION public.list_supabase_branches(p_parent_ref text DEFAULT NULL)
 RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO '' AS $function$
BEGIN
  RETURN qvm_new_apps.list_supabase_branches(p_parent_ref);
END;
$function$;
GRANT EXECUTE ON FUNCTION public.list_supabase_branches(text) TO authenticated;
