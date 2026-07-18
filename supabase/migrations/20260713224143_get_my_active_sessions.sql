-- Synced from QVM/test branch applied migration history (version 20260713224143, name: get_my_active_sessions)
-- Read-only: returns ONLY the calling user's own browser sessions (auth.uid()), grouped by
-- device + IP, non-expired and recently active. Excludes API/service user-agents (axios, Postman,
-- Deno edge runtime, curl…) which are not real devices. is_current flags the caller's live session.
CREATE OR REPLACE FUNCTION public.get_my_active_sessions(p_days int DEFAULT 30)
RETURNS TABLE(
  ip text,
  user_agent text,
  first_seen timestamptz,
  last_seen timestamptz,
  session_count bigint,
  is_current boolean
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO auth, public
AS $$
  WITH cur AS (
    SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'session_id' AS sid
  )
  SELECT
    host(s.ip) AS ip,
    s.user_agent,
    min(s.created_at) AS first_seen,
    max(coalesce(s.refreshed_at::timestamptz, s.updated_at)) AS last_seen,
    count(*) AS session_count,
    bool_or(s.id::text = (SELECT sid FROM cur)) AS is_current
  FROM auth.sessions s
  WHERE s.user_id = auth.uid()
    AND s.user_agent ILIKE 'Mozilla/%'
    AND (s.not_after IS NULL OR s.not_after > now())
    AND coalesce(s.refreshed_at::timestamptz, s.updated_at) > now() - make_interval(days => greatest(1, p_days))
  GROUP BY host(s.ip), s.user_agent
  ORDER BY bool_or(s.id::text = (SELECT sid FROM cur)) DESC,
           max(coalesce(s.refreshed_at::timestamptz, s.updated_at)) DESC
$$;

REVOKE ALL ON FUNCTION public.get_my_active_sessions(int) FROM public;
GRANT EXECUTE ON FUNCTION public.get_my_active_sessions(int) TO authenticated;;
