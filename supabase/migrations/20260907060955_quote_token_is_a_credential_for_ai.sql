-- The vendor pricing a quote from an emailed link has no Supabase session.
--
-- Moving the AI call behind an edge function that requires a signed-in user quietly broke
-- «املأ الأسعار من ملف» on the magic-link page: that visitor is `anon` by design, holding one
-- opaque time-limited token instead of an account. The feature worked before only because the
-- key was in the bundle, which is precisely what had to stop.
--
-- So the token becomes the credential. It is already what the page uses to read the quote and
-- to save prices against it — a visitor holding a live one is exactly the person entitled to
-- have their own price list read.
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
  return coalesce((v->>'status')::boolean, false)
     and v->'data' is not null
     and v->'data' <> 'null'::jsonb;
end
$function$;

revoke all on function qvm_new_apps.quote_token_is_live(uuid) from public, anon, authenticated;
grant execute on function qvm_new_apps.quote_token_is_live(uuid) to service_role;
