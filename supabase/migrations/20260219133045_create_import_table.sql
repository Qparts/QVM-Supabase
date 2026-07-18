-- Synced from QVM/test branch applied migration history (version 20260219133045, name: create_import_table)
-- Create regular table for import
CREATE TABLE IF NOT EXISTS temp_quotations_import (
    order_number TEXT,
    plate_number TEXT,
    delivery_type INTEGER,
    account_manager TEXT,
    service_advisor TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
);;
