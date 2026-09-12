-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- The email side of the inbox could not be read, answered or started.
--
-- Every thread-scoped call gates on wa_require(wa_account_of_thread(id)) — the WhatsApp
-- number the conversation belongs to. An email conversation belongs to a mailbox and has
-- no number, so that lookup returned null, wa_can(null) was false, and the gate refused
-- everybody. Alongside it the list filtered on `wa_account_id = any(my numbers)`, which a
-- null can never satisfy, so an ingested email was stored and then invisible.
--
-- One rule fixes both: a conversation with no number is an email one, and mailboxes are
-- company-wide. email_list_accounts already shows every mailbox to every internal user,
-- so the same people may read and answer what arrives in them. Putting it in wa_can
-- repairs all nine thread-scoped functions at once instead of nine near-identical edits
-- that would drift apart later.

create or replace function qvm_new_apps.wa_can(
  p_wa_account_id bigint, p_min_role text default 'viewer')
returns boolean
language sql
stable security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
  select case
    -- No number on the conversation: it is an email one. The mailbox list is already
    -- open to all internal staff, so reading and answering follows the same line.
    when p_wa_account_id is null then qvm_new_apps.wa_is_internal()
    else qvm_new_apps.wa_role_rank(qvm_new_apps.wa_my_role(p_wa_account_id))
           >= qvm_new_apps.wa_role_rank(p_min_role)
         and coalesce((select is_active and not is_legacy or p_min_role = 'viewer'
                         from qvm_new_apps.wa_accounts where wa_account_id = p_wa_account_id), false)
  end;
$function$;


-- Starting an email conversation from the panel.
--
-- Inbound mail creates its contact and thread inside email_ingest_message; this is the
-- same shape for the other direction, so a conversation we start and one they start are
-- the same row in the same table, and the first reply threads onto it either way.

create or replace function qvm_new_apps.wa_start_email_thread(
  p_account_id bigint,
  p_to_email text,
  p_subject text,
  p_display_name text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'qvm_new_apps', 'public'
as $function$
declare
  v_addr text := lower(btrim(coalesce(p_to_email, '')));
  v_subject text := nullif(btrim(coalesce(p_subject, '')), '');
  v_acct record; v_contact bigint; v_thread bigint; v_key text;
begin
  if not qvm_new_apps.wa_is_internal() then
    return jsonb_build_object('status', false, 'message', 'forbidden', 'data', null);
  end if;

  -- Deliberately loose: anything with an @ and a dot after it. A stricter pattern here
  -- would reject addresses that exist, and the mail server is the real judge anyway.
  if v_addr !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('status', false, 'message', 'a valid email address is required', 'data', null);
  end if;
  if v_subject is null then
    return jsonb_build_object('status', false, 'message', 'a subject is required', 'data', null);
  end if;

  select account_id, email_address, status into v_acct
    from qvm_new_apps.email_accounts
   where account_id = p_account_id and status <> 'disconnected';
  if v_acct.account_id is null then
    return jsonb_build_object('status', false, 'message', 'unknown or disconnected mailbox', 'data', null);
  end if;
  if v_addr = lower(v_acct.email_address) then
    return jsonb_build_object('status', false, 'message', 'that is this mailbox’s own address', 'data', null);
  end if;

  insert into qvm_new_apps.wa_contacts (email, email_account_id, display_name, chat_type)
  values (v_addr, p_account_id, nullif(btrim(coalesce(p_display_name, '')), ''), 'individual')
  on conflict (lower(email), email_account_id) where email is not null do update
    set display_name = coalesce(qvm_new_apps.wa_contacts.display_name, excluded.display_name)
  returning wa_contact_id into v_contact;

  -- A known vendor keeps its link, the same way an inbound mail from them would.
  update qvm_new_apps.wa_contacts c set vendor_id = v.vendor_id
    from (select vendor_id from qvm_new_apps.vendors
           where lower(email) = v_addr and email is not null limit 1) v
   where c.wa_contact_id = v_contact and c.vendor_id is null;

  -- Same key the ingest uses, so their reply — which will come back as «Re: <subject>» —
  -- lands on this thread rather than opening a second one beside it.
  v_key := coalesce(qvm_new_apps.email_conversation_key(v_subject), v_subject);

  insert into qvm_new_apps.wa_threads (wa_contact_id, channel, email_account_id, subject, email_conversation_key)
  values (v_contact, 'email', p_account_id, v_subject, v_key)
  on conflict (wa_contact_id, email_conversation_key) where channel = 'email'
    do update set subject = coalesce(qvm_new_apps.wa_threads.subject, excluded.subject)
  returning thread_id into v_thread;

  perform qvm_new_apps.wa_revive_thread(v_thread);

  return jsonb_build_object('status', true, 'message', 'ok',
    'data', jsonb_build_object('thread_id', v_thread, 'contact_id', v_contact));
end $function$;

revoke execute on function qvm_new_apps.wa_start_email_thread(bigint, text, text, text) from public;
grant execute on function qvm_new_apps.wa_start_email_thread(bigint, text, text, text) to authenticated, anon;
