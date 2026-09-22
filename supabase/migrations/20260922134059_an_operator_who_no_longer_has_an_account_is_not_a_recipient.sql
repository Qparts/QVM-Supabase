-- An operator who no longer has an account is not a recipient.
--
-- `user_data` outlives `auth.users`: deleting a person leaves their row behind, and one such
-- orphan is on this database right now. The first version of `wallet_operator_ids()` read only
-- `user_data`, so every top-up request wrote a notification addressed to somebody who cannot
-- sign in to read it.
--
-- Harmless in the sense that nothing breaks, which is exactly why it would have stayed: the
-- count on screen would say seven people were told when six were, and the seventh would be
-- invisible. Found by joining the recipients to real accounts during the test rather than
-- trusting the number the insert returned.
create or replace function qvm_new_apps.wallet_operator_ids()
returns setof uuid
language sql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $$
  select u.user_id
    from qvm_new_apps.user_data u
   where (u.user_role in (172, 173, 269) or u.user_type = 185)
     and not exists (select 1 from qvm_new_apps.user_companies uc where uc.user_id = u.user_id)
     and u.user_vendor is null
     -- The account has to still exist. A message to a deleted user is a row nobody will read.
     and exists (select 1 from auth.users au where au.id = u.user_id);
$$;

-- The rows already addressed to nobody. Deleted rather than left: a notification for an account
-- that cannot exist is not history, it is litter — and it makes every unread count wrong for as
-- long as it sits there.
delete from qvm_new_apps.notifications n
 where n.target_type = 'user'
   and n.target_user_id is not null
   and not exists (select 1 from auth.users au where au.id = n.target_user_id);
