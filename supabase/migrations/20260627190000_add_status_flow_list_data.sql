BEGIN;

-- Add new statuses for the quotation item lifecycle (list_id = 3)
INSERT INTO qvm_new_apps.list_data (list_data_id, list_id, list_data, created_at, updated_at)
OVERRIDING SYSTEM VALUE
VALUES
  (235, 3, 'Ready For Quotation', now(), now()),
  (236, 3, 'Extract PN', now(), now()),
  (237, 3, 'Sent To Vendor', now(), now())
ON CONFLICT (list_data_id) DO UPDATE SET
  list_id = EXCLUDED.list_id,
  list_data = EXCLUDED.list_data,
  updated_at = now();

COMMIT;
