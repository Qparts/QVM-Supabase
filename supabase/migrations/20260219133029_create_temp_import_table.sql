-- Synced from QVM/test branch applied migration history (version 20260219133029, name: create_temp_import_table)
-- Step 2D: Create temporary table for import
CREATE TEMP TABLE temp_quotations_import (
    order_number TEXT,
    plate_number TEXT,
    delivery_type INTEGER,
    account_manager TEXT,
    service_advisor TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);;
