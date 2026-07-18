-- Synced from QVM/test branch applied migration history (version 20260426001047, name: qpd412_filter_soft_deleted_notes_in_fetch_notes_test_branch)
BEGIN;

-- Ensure soft-delete columns exist on branch
ALTER TABLE qvm_new_apps.notes
  ADD COLUMN IF NOT EXISTS is_deleted boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deleted_at timestamptz NULL,
  ADD COLUMN IF NOT EXISTS deleted_by uuid NULL;

-- Update qvm_new_apps.fetch_notes to exclude soft-deleted rows
CREATE OR REPLACE FUNCTION qvm_new_apps.fetch_notes(
  p_note_type text,
  p_type_id bigint,
  p_is_internal boolean DEFAULT NULL
)
RETURNS TABLE (
  note_id bigint,
  note_description text,
  note_attachment text,
  created_at timestamptz,
  user_name text,
  user_id uuid,
  is_internal boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT
    n.note_id,
    n.note_description,
    n.note_attachment,
    n.created_at,
    u.user_name,
    n.user_id,
    n.is_internal
  FROM qvm_new_apps.notes n
  LEFT JOIN qvm_new_apps.user_data u
    ON u.user_id = n.user_id
  WHERE n.note_type = p_note_type
    AND n.type_id = p_type_id
    AND (p_is_internal IS NULL OR n.is_internal = p_is_internal)
    AND COALESCE(n.is_deleted, false) = false
  ORDER BY n.created_at DESC;
$$;

COMMIT;;
