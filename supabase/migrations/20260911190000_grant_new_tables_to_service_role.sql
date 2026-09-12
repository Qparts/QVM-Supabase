-- The service role can reach the tables added with the workshop tier.
--
-- create_client_user came back with "Workshop not found" for a workshop that plainly exists. The
-- lookup was not failing to find it — it was failing outright:
--
--   42501  permission denied for schema qvm_new_apps
--
-- client_branches carries grants for anon, authenticated and service_role because someone granted
-- them years ago, table by table. GRANT ... ON ALL TABLES is a one-off act on the tables that exist
-- at the time; it says nothing about tables created afterwards. So every table added with the
-- workshop tier — companies, workshops, cities, languages, the description tables — arrived with no
-- grants at all, and the only reason the app worked is that its own reads go through SECURITY
-- DEFINER functions, which run as the owner and never consult these grants. The edge function does
-- not: it queries PostgREST with the service key, as itself.
--
-- ALTER DEFAULT PRIVILEGES is the part that stops this recurring. Without it the next table added
-- lands in exactly the same hole, and the symptom is never "permission denied" where you can see it
-- — it is whatever the calling code says when a query returns nothing.

GRANT USAGE ON SCHEMA qvm_new_apps TO service_role;

GRANT ALL ON ALL TABLES    IN SCHEMA qvm_new_apps TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA qvm_new_apps TO service_role;

ALTER DEFAULT PRIVILEGES IN SCHEMA qvm_new_apps GRANT ALL ON TABLES    TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA qvm_new_apps GRANT ALL ON SEQUENCES TO service_role;

-- Reference data the app may read directly one day: the language set and the city list are public
-- facts about the platform, not client data. Everything about companies, workshops, branches and
-- who works at them stays reachable only through the gated functions.
GRANT SELECT ON qvm_new_apps.languages,
                qvm_new_apps.cities, qvm_new_apps.cities_descriptions,
                qvm_new_apps.regions, qvm_new_apps.regions_descriptions
  TO authenticated;
