-- Synced from QVM/test branch applied migration history (version 20260308140932, name: grant_auth_hook_access_qvm_new_apps)
GRANT USAGE ON SCHEMA qvm_new_apps TO supabase_auth_admin;
GRANT EXECUTE ON FUNCTION qvm_new_apps.get_user_data(uuid) TO supabase_auth_admin;
;
