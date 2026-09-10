-- «function qvm_new_apps.is_qparts_admin() is not unique», and the WhatsApp inbox stops.
--
-- There were two of them:
--
--   is_qparts_admin()                              -- from 20260809100500_notification_settings
--   is_qparts_admin(p_user_id uuid DEFAULT auth.uid())
--
-- A bare call matches both — the second through its default — so Postgres refuses to choose and
-- every caller fails. wa_my_role() is one of them, which is why the inbox reports this and shows
-- no conversations: the page is fine, the role lookup underneath it cannot run.
--
-- The second one is in no migration and in no ledger entry. It was created straight onto the
-- branch, so nothing in the repository could have told anyone it existed, and it broke a feature
-- written months earlier that had not been touched since. This is the same failure as the
-- WhatsApp supervisor that lived only on the VPS.
--
-- Which one to remove is decided by the callers, not by which is older. Both forms are in real
-- use: thirteen functions pass an argument — the whole admin_* family and
-- is_qparts_admin_or_service — while wa_my_role, the two notification-settings functions and one
-- RLS policy call it bare. Dropping the argument-taking one breaks thirteen; dropping the
-- no-argument one breaks nothing, because its callers land on the survivor's DEFAULT auth.uid().
--
-- The rule they encode is the same. The old body joined list_data to find the role named «Qparts
-- Admin»; the survivor compares user_role to 172, which is that row's id. The survivor also
-- requires deleted_at is null, so a deleted administrator stops being an administrator — the one
-- behavioural difference, and in the safe direction.

-- The policy binds to a specific function, so it has to let go before the drop and be written
-- back afterwards. Identical text: it resolves to the survivor once the ambiguity is gone.
drop policy if exists notification_settings_select on qvm_new_apps.notification_settings;

drop function if exists qvm_new_apps.is_qparts_admin();

create policy notification_settings_select on qvm_new_apps.notification_settings
  for select using (qvm_new_apps.is_qparts_admin());

-- The survivor was created with no ACL at all, which in Postgres means EXECUTE for PUBLIC. The
-- grants the dropped one carried are restored explicitly rather than left implicit.
revoke all on function qvm_new_apps.is_qparts_admin(uuid) from public;
grant execute on function qvm_new_apps.is_qparts_admin(uuid) to authenticated, anon, service_role;

-- Fail loudly if this ever comes back. A second overload is not a compile error, it is a working
-- database until the first bare call — which is how it reached the test site unnoticed.
do $$
declare v_n integer;
begin
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'qvm_new_apps' and p.proname = 'is_qparts_admin';
  if v_n <> 1 then
    raise exception 'is_qparts_admin still has % overloads — a bare call cannot resolve', v_n;
  end if;
end
$$;
