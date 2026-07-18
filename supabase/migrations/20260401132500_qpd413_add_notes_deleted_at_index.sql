BEGIN;

-- Create an index on deleted_at to support soft-delete lookups
CREATE INDEX IF NOT EXISTS idx_notes_deleted_at ON qvm_new_apps.notes (deleted_at);

COMMIT;
