-- The approval page saves the customer's reference through the API's default schema, like every
-- other approval call; the mailed link has no session and cannot reach qvm_new_apps at all. So the
-- two reference functions get the same public wrappers the rest of the approval calls have.
create or replace function public.set_approval_reference(p_token uuid, p_reference text)
returns jsonb language sql security definer set search_path to 'qvm_new_apps', 'public'
as $function$ select qvm_new_apps.set_approval_reference(p_token, p_reference); $function$;

create or replace function public.set_approval_reference_as_user(p_quotation_id bigint, p_reference text)
returns jsonb language sql security definer set search_path to 'qvm_new_apps', 'public'
as $function$ select qvm_new_apps.set_approval_reference_as_user(p_quotation_id, p_reference); $function$;

revoke all on function public.set_approval_reference(uuid, text) from public;
revoke all on function public.set_approval_reference_as_user(bigint, text) from public;
grant execute on function public.set_approval_reference(uuid, text) to anon, authenticated, service_role;
grant execute on function public.set_approval_reference_as_user(bigint, text) to authenticated, service_role;

notify pgrst, 'reload schema';
