-- The extraction event log admits a photo change.
--
-- set_extract_photos writes a 'photo_updated' event, and the log's check constraint listed every
-- event type but that one, so adding a photo failed with 23514. The constraint now names it.
ALTER TABLE qvm_new_apps.quotation_item_extraction_events
  DROP CONSTRAINT IF EXISTS quotation_item_extraction_events_event_type_check;
ALTER TABLE qvm_new_apps.quotation_item_extraction_events
  ADD CONSTRAINT quotation_item_extraction_events_event_type_check
  CHECK (event_type = ANY (ARRAY['pn_draft', 'pn_saved', 'pn_cleared', 'pn_reopened', 'description_amended',
                                 'unclear_raised', 'unclear_resolved', 'item_added', 'item_removed',
                                 'alt_added', 'alt_removed', 'photo_updated']));

CREATE OR REPLACE FUNCTION public.approval_flow_version()
 RETURNS integer LANGUAGE sql STABLE AS $$ SELECT 38 $$;
