-- The carrier call log was writing to a table that refused every row.
--
-- The Mrsool function says it «records every carrier call, successful or not, in the log the app
-- already has a page for», and it records nothing. Two reasons, both of which the insert's
-- try/catch swallowed:
--
--   1. `trigger_type` is checked against exactly ('send_rfq', 'send_po'). Every carrier trigger
--      name failed that check.
--   2. `reference_id` is NOT NULL, and a connection test is about nothing in particular.
--
-- So the one place anybody would look to find out what a carrier actually answered has been
-- empty since the day it was written, and the failure was invisible by design — the catch is
-- there so that a logging problem can never stop a dispatch, which also means it can never be
-- noticed.
--
-- Widened rather than replaced: the intent was one log with one page, and `trigger_type` is
-- already the column that says which kind of call a row is.
alter table qvm_new_apps.webhook_logs
  drop constraint if exists webhook_logs_trigger_type_check;

alter table qvm_new_apps.webhook_logs
  add constraint webhook_logs_trigger_type_check
  check (trigger_type in (
    'send_rfq', 'send_po',
    -- Outbound carrier calls and the webhooks that come back.
    'mrsool_test', 'mrsool_price', 'mrsool_create', 'mrsool_cancel',
    'mrsool_test_status', 'mrsool_webhook'));

-- A connection test refers to no shipment. NOT NULL here forces the caller to invent a number,
-- and an invented reference is worse in a log than an absent one.
alter table qvm_new_apps.webhook_logs
  alter column reference_id drop not null;

comment on column qvm_new_apps.webhook_logs.reference_id is
  'What the call was about — a shipment for a carrier call, an RFQ or PO for the others. Null '
  'for calls that are about nothing, such as a connection test.';

-- Same reasoning: a GET has no request body, and '{}' would read as «we sent an empty object».
alter table qvm_new_apps.webhook_logs
  alter column request_payload drop not null;
