-- Synced from QVM/test branch applied migration history (version 20260326071452, name: attachments_bucket_policies)
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'Attachments insert for authenticated'
  ) THEN
    CREATE POLICY "Attachments insert for authenticated"
    ON storage.objects
    FOR INSERT
    TO authenticated
    WITH CHECK (
      bucket_id = (SELECT id FROM storage.buckets WHERE name = 'attachments')
    );
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects' AND policyname = 'Attachments select for authenticated'
  ) THEN
    CREATE POLICY "Attachments select for authenticated"
    ON storage.objects
    FOR SELECT
    TO authenticated
    USING (
      bucket_id = (SELECT id FROM storage.buckets WHERE name = 'attachments')
    );
  END IF;
END $$;;
