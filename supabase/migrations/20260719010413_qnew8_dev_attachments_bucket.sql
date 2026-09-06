-- Recovered from the QVM/dev branch database's own migration history.
-- Applied through the Supabase dashboard and recorded in
-- supabase_migrations.schema_migrations, but never committed as a file, which is what
-- made branch deploys fail with "Remote migration versions not found in local
-- migrations directory". Body is verbatim from that table's `statements` column.

-- Mirror prod's public 'attachments' bucket + storage policies on dev, so client uploads work locally.
INSERT INTO storage.buckets (id, name, public)
VALUES ('attachments', 'attachments', true)
ON CONFLICT (id) DO UPDATE SET public = true;

DROP POLICY IF EXISTS "Attachments insert for authenticated" ON storage.objects;
CREATE POLICY "Attachments insert for authenticated" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'attachments');

DROP POLICY IF EXISTS "Attachments select for authenticated" ON storage.objects;
CREATE POLICY "Attachments select for authenticated" ON storage.objects
  FOR SELECT TO authenticated USING (bucket_id = 'attachments');
