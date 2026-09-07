-- quote_token_is_live judged every token dead.
--
-- It read the wrapper's `status` as a boolean, but get_vendor_quotation_by_token answers with
-- the string 'success' — and 'success'::boolean does not raise, it just fails the test. So the
-- magic-link vendor was refused the AI call with a live token in their hand, and the refusal
-- looked identical to an expired one.
--
-- Reading the field as text and accepting either convention, because a caller should not have
-- to know which one the function underneath happens to use this month.
create or replace function qvm_new_apps.quote_token_is_live(p_token uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare v jsonb;
begin
  if p_token is null then return false; end if;
  -- Asked through the same function the page itself is gated by, rather than reimplementing
  -- the rule: expiry, revocation and whatever else it checks stay defined in one place.
  begin
    v := qvm_new_apps.get_vendor_quotation_by_token(p_token);
  exception when others then
    return false;
  end;
  -- Accepts either shape, because a caller of this should not have to know which convention
  -- the underlying function happens to use today.
  return lower(coalesce(v->>'status','')) in ('success','true','ok')
     and coalesce(v->'data', 'null'::jsonb) <> 'null'::jsonb;
end
$function$;

revoke all on function qvm_new_apps.quote_token_is_live(uuid) from public, anon, authenticated;
grant execute on function qvm_new_apps.quote_token_is_live(uuid) to service_role;
