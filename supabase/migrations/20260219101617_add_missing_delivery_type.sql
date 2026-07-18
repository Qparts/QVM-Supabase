-- Synced from QVM/test branch applied migration history (version 20260219101617, name: add_missing_delivery_type)
-- Add "Next Working Slot" to delivery_type list
INSERT INTO qvm_new_apps.list_data (list_id, list_data, created_at, updated_at)
VALUES (10, 'Next Working Slot', NOW(), NOW());;
