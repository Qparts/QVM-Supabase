-- Synced from QVM/test branch applied migration history (version 20260326072113, name: attachments_bucket_policies_fix)
-- Replace incorrect policies with correct bucket_id match
DROP POLICY IF EXISTS "Attachments insert for authenticated" ON storage.objects;
DROP POLICY IF EXISTS "Attachments select for authenticated" ON storage.objects;

CREATE POLICY "Attachments insert for authenticated"
ON storage.objects
FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'attachments'
);

CREATE POLICY "Attachments select for authenticated"
ON storage.objects
FOR SELECT
TO authenticated
USING (
  bucket_id = 'attachments'
);;
