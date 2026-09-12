-- "Internal Branch User" becomes "Procurement User".
--
-- The old name described where the account was scoped rather than what the person does, which is
-- why nobody could ever say it without explaining it. They are the buying desk — المشتريات — over
-- one company's branches.
--
-- Only the label moves. The role keeps id 271, so every user_data row, every permission this
-- company has set, and every menu keyed on the id are untouched. Renaming a role should not be a
-- data migration, and here it is not.
--
-- The name is load-bearing in two places, both of which move with it: config/navPages.ts keys the
-- starting state of the permissions grid by role name, and permission_roles was seeded by name —
-- though that table stores the id, so its rows survive on their own.

UPDATE qvm_new_apps.list_data
   SET list_data = 'Procurement User', updated_at = now()
 WHERE list_id = 16
   AND lower(btrim(list_data)) = 'internal branch user';
