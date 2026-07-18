-- Synced from QVM/test branch applied migration history (version 20260218112628, name: sync_user_names_with_main_users_main_data)
-- Sync remaining user_name values to match main branch users_main_data (by normalized email)

UPDATE qvm_new_apps.user_data ud
SET user_name = v.main_user_name
FROM (
  VALUES
    ('pac-darb@petromin.com', 'Mohamed Saeed'),
    ('turbocare27@gmail.com', 'Mohamed kamal Mohamed'),
    ('tech-dream@hotmail.com', 'Hamdy AlMarakby'),
    ('mw-80101-jcs@joil.com.sa', 'Munsiah Workshop'),
    ('workshop@gmail.com', 'Mohamed Sameh'),
    ('azza@qparts.co', 'Azza Roshdy'),
    ('mohammeds@autolead.sa', '')
) AS v(email_norm, main_user_name)
WHERE LOWER(TRIM(ud.email)) = v.email_norm
  AND ud.user_name IS DISTINCT FROM v.main_user_name;;
