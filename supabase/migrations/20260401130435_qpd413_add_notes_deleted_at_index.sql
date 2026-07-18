-- Synced from QVM/test branch applied migration history (version 20260401130435, name: qpd413_add_notes_deleted_at_index)
BEGIN;

-- Create an index on deleted_at to support soft-delete lookups
CREATE INDEX IF NOT EXISTS idx_notes_deleted_at ON qvm_new_apps.notes (deleted_at);

COMMIT;;
