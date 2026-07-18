-- Synced from QVM/test branch applied migration history (version 20260308142514, name: grant_auth_hook_schema_select)
GRANT USAGE ON SCHEMA qvm_new_apps TO supabase_auth_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA qvm_new_apps TO supabase_auth_admin;
;
