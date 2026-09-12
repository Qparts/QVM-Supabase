-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Where a quotation file came from.
--
-- Until now every row here was a hand-upload, so the column was implicit. A vendor who
-- answers an RFQ on WhatsApp is answering it just as much as one who uses the portal, and
-- their file belongs on the comparison screen — but a buyer looking at it needs to know it
-- arrived in a conversation, and needs a way back to that conversation to read what was
-- said around it. Hence the origin and the two pointers.
--
-- The file itself is copied into the public `attachments` bucket rather than referenced in
-- place: WhatsApp media lives in a private bucket behind ten-minute signed URLs, and a
-- purchase order that carries an expiring link carries nothing at all.

alter table qvm_new_apps.quotation_attachments
  add column if not exists source text not null default 'upload',
  add column if not exists wa_message_id bigint,
  add column if not exists wa_thread_id bigint;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'qvm_new_apps.quotation_attachments'::regclass
      and conname = 'quotation_attachments_source_chk'
  ) then
    alter table qvm_new_apps.quotation_attachments
      add constraint quotation_attachments_source_chk
      check (source in ('upload', 'whatsapp', 'email'));
  end if;
end $$;

-- on delete set null, not cascade: deleting a conversation message must not silently take
-- the quote file off the order it was priced from. The link goes, the file stays.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'qvm_new_apps.quotation_attachments'::regclass
      and conname = 'quotation_attachments_wa_message_fk'
  ) then
    alter table qvm_new_apps.quotation_attachments
      add constraint quotation_attachments_wa_message_fk
      foreign key (wa_message_id) references qvm_new_apps.wa_messages(message_id)
      on delete set null;
  end if;
end $$;

-- One message links to one order once. Pressing the button twice was otherwise two copies
-- of the same file sitting in the same vendor column.
create unique index if not exists quotation_attachments_wa_msg_uniq
  on qvm_new_apps.quotation_attachments (quotation_id, wa_message_id)
  where wa_message_id is not null;

-- The inbox asks "which files in this conversation are already linked?" on every open.
create index if not exists quotation_attachments_wa_thread_idx
  on qvm_new_apps.quotation_attachments (wa_thread_id)
  where wa_thread_id is not null;
