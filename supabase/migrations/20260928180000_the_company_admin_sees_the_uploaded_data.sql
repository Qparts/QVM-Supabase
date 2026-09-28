-- The Company Admin sees Uploaded Data.
--
-- The page was hidden from the buying desk on request and never given to the Company Admin, so a
-- company's admin could not reach the company's own agency lists, stock and purchases. It becomes
-- a company page (a Company Admin may hand it to their people) and joins the Company Admin's
-- default pages. The Qparts Admin was never restricted.

set search_path to qvm_new_apps, public;

update qvm_new_apps.permission_pages
   set is_company_page = true
 where nav_id = 'uploaded-data';

insert into qvm_new_apps.permission_role_defaults (user_type, role_id, nav_id)
select 0, qvm_new_apps.company_admin_role_id(), 'uploaded-data'
 where not exists (select 1 from qvm_new_apps.permission_role_defaults
                    where role_id = qvm_new_apps.company_admin_role_id()
                      and user_type = 0 and nav_id = 'uploaded-data');
