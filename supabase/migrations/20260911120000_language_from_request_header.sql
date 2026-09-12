-- The reader's language now arrives as a request header.
--
-- PostgREST cannot be given a session variable by the browser, but it does publish the request
-- headers to SQL. The client sets x-app-lang on every call, so the resolving views answer in the
-- language the user is actually looking at rather than always in the default.
--
-- The set_config('app.lang', …) path is kept ahead of it: server-side callers — edge functions,
-- scheduled jobs, anything holding a raw connection — have no headers to read.
CREATE OR REPLACE FUNCTION qvm_new_apps.current_language_id()
RETURNS integer LANGUAGE sql STABLE SET search_path TO 'qvm_new_apps', 'public' AS $$
  SELECT COALESCE(
    (SELECT l.language_id FROM qvm_new_apps.languages l
      WHERE l.is_active AND l.code = NULLIF(current_setting('app.lang', true), '')),
    (SELECT l.language_id FROM qvm_new_apps.languages l
      WHERE l.is_active
        AND l.code = lower(NULLIF(
              COALESCE(current_setting('request.headers', true)::jsonb ->> 'x-app-lang', ''), ''))),
    qvm_new_apps.default_language_id());
$$;
