-- Synced from QVM/test branch applied migration history (version 20260308142706, name: revoke_schema_grants_apply_minimal)
REVOKE SELECT ON ALL TABLES IN SCHEMA qvm_new_apps FROM supabase_auth_admin;
GRANT USAGE ON SCHEMA qvm_new_apps TO supabase_auth_admin;
GRANT SELECT ON TABLE qvm_new_apps.user_data TO supabase_auth_admin;
GRANT SELECT ON TABLE qvm_new_apps.list_data TO supabase_auth_admin;
;
