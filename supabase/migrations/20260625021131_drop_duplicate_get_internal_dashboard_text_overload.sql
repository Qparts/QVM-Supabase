-- Synced from QVM/test branch applied migration history (version 20260625021131, name: drop_duplicate_get_internal_dashboard_text_overload)

DROP FUNCTION IF EXISTS public.get_internal_dashboard(
  p_user_id uuid,
  p_search text,
  p_date_from timestamptz,
  p_date_to timestamptz,
  p_account_managers text[],
  p_clients integer[],
  p_branches integer[],
  p_brands integer[],
  p_statuses integer[],
  p_mode text,
  p_view text,
  p_limit integer,
  p_offset integer
);
;
