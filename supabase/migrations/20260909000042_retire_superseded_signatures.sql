-- Retire the old signatures that production still carries, so the new ones can land alone.
--
-- This one only does anything on production. On dev every drop is a no-op, because dev replaced
-- these functions properly when their signatures changed.
--
-- Why it has to exist. Production's schema was patched by hand for two weeks while the migration
-- ledger stood still, so it holds the *previous* signature of nineteen functions that this release
-- redefines with a different argument list:
--
--   wa_get_device_state()              →  wa_get_device_state(p_wa_account_id bigint)
--   wa_list_assignees()                →  wa_list_assignees(p_wa_account_id bigint)
--   uploaded_records_get(5 args)       →  uploaded_records_get(6 args)
--   is_qparts_admin()                  →  is_qparts_admin(p_user_id uuid default auth.uid())
--   … and fifteen more, the whole single-number WhatsApp surface
--
-- CREATE OR REPLACE with a different argument list does not replace anything. It adds a second
-- function of the same name, and from that moment a call that matches both — which is every call
-- where the extra argument has a default, and every bare call — raises
--
--     function qvm_new_apps.<name>(...) is not unique
--
-- That is not hypothetical here. It is exactly what took the WhatsApp inbox down on the test
-- branch on 2026-09-10: one duplicate of is_qparts_admin, added by a migration that had no idea
-- the other one existed, and every caller died. Releasing this set without this file would do the
-- same thing to production in nineteen places at once.
--
-- Dropping is safe for the WhatsApp pair specifically, and the logs say so: production's own
-- frontend already calls the new signatures, and the server answers 404 because only the old ones
-- are there — sixteen times for wa_get_device_state in a single day. The old functions are
-- already unreachable. This removes them rather than leaving them to collide.
--
-- `if exists` throughout, so this is harmless wherever the old signature was never present.

-- The pricing and admin pair.
drop function if exists qvm_new_apps.is_qparts_admin();
drop function if exists qvm_new_apps.process_cancellation_request(p_confirmed_item_id integer, p_cancellation_reason_id integer, p_user_id uuid);
drop function if exists qvm_new_apps.uploaded_records_get(p_kind text, p_search text, p_make text, p_limit integer, p_offset integer);

-- The single-number WhatsApp surface, superseded by the multi-number one that takes an account id.
drop function if exists qvm_new_apps.wa_avatars_pending(p_limit integer);
drop function if exists qvm_new_apps.wa_claim_outbox(p_limit integer);
drop function if exists qvm_new_apps.wa_complete_outbox(p_outbox_id bigint, p_ok boolean, p_wa_message_id text, p_error text);
drop function if exists qvm_new_apps.wa_create_vendor_from_contact(p_wa_contact_id bigint, p_vendor_name text);
drop function if exists qvm_new_apps.wa_get_device_state();
drop function if exists qvm_new_apps.wa_health_check();
drop function if exists qvm_new_apps.wa_ingest_message(p_wa_message_id text, p_jid text, p_phone text, p_display_name text, p_body text, p_media_url text, p_media_mime text, p_wa_timestamp timestamp with time zone, p_raw jsonb, p_media_kind text, p_media_name text, p_chat_type text, p_sender_jid text, p_sender_name text, p_reply_to_wa_id text);
drop function if exists qvm_new_apps.wa_ingest_outbound(p_wa_message_id text, p_jid text, p_phone text, p_body text, p_media_url text, p_media_mime text, p_wa_timestamp timestamp with time zone, p_raw jsonb, p_media_kind text, p_media_name text, p_reply_to_wa_id text);
drop function if exists qvm_new_apps.wa_list_assignees();
drop function if exists qvm_new_apps.wa_list_threads(p_status text, p_search text, p_only_mine boolean, p_limit integer, p_offset integer, p_channel text);
drop function if exists qvm_new_apps.wa_request_pairing(p_disconnect boolean);
drop function if exists qvm_new_apps.wa_set_avatar(p_wa_contact_id bigint, p_avatar_path text, p_avatar_id text, p_push_name text);
drop function if exists qvm_new_apps.wa_set_device_state(p_device_id text, p_state text, p_jid text, p_qr_png text, p_qr_ttl_seconds integer, p_error text, p_clear_pair_request boolean);
drop function if exists qvm_new_apps.wa_set_typing(p_phone text, p_seconds integer);
drop function if exists qvm_new_apps.wa_start_thread(p_phone text, p_vendor_id integer, p_display_name text);
drop function if exists qvm_new_apps.wa_update_delivery(p_wa_message_id text, p_status text);

-- Nothing may be left with two definitions. A duplicate is not a compile error — it is a working
-- database until the first ambiguous call, which is precisely how this reached production
-- unnoticed. Fail the release here instead, where it is cheap.
do $$
declare r record; v_bad text := '';
begin
  for r in
    select p.proname, count(*) as n
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'qvm_new_apps'
       and p.proname in ('is_qparts_admin','process_cancellation_request','uploaded_records_get',
         'wa_avatars_pending','wa_claim_outbox','wa_complete_outbox','wa_create_vendor_from_contact',
         'wa_get_device_state','wa_health_check','wa_ingest_message','wa_ingest_outbound',
         'wa_list_assignees','wa_list_threads','wa_request_pairing','wa_set_avatar',
         'wa_set_device_state','wa_set_typing','wa_start_thread','wa_update_delivery')
     group by p.proname having count(*) > 1
  loop
    v_bad := v_bad || format('%s has %s definitions; ', r.proname, r.n);
  end loop;
  if v_bad <> '' then
    raise exception 'superseded signatures survived: %', v_bad;
  end if;
end
$$;
