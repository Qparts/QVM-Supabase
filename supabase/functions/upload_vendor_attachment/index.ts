// QNEW-8 — attachment upload for the vendor's public magic link.
//
// The magic-link page has no Supabase session: the vendor is `anon`, and the storage policies on
// the `attachments` bucket only allow `authenticated`, so a direct upload from that page fails with
// "new row violates row-level security policy". This mirrors what save_vendor_quotation_by_token
// already does for prices — the opaque access_token is the credential, it is validated here, and
// the write then happens with the service role.
//
// The client sends only the file and the token. quotation_id / vendor_id / quotation_vendor_id are
// read from the token's own row, never taken from the request, so a caller can't aim an upload at
// an order the token doesn't belong to.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'apikey, content-type, x-client-info, authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });

// Keep this in step with classifyAttachmentType() in services/apiService.ts.
function classifyAttachmentType(name: string, mime: string): string {
  const t = (mime || '').toLowerCase();
  const n = (name || '').toLowerCase();
  if (t.startsWith('image/') || /\.(png|jpe?g|gif|webp|heic|heif|bmp|tiff?)$/.test(n)) return 'image';
  if (t === 'application/pdf' || n.endsWith('.pdf')) return 'pdf';
  if (t.includes('sheet') || n.endsWith('.xlsx') || n.endsWith('.xls') || n.endsWith('.csv')) return 'excel';
  if (t.includes('word') || n.endsWith('.doc') || n.endsWith('.docx')) return 'doc';
  return 'other';
}

const MAX_BYTES = 20 * 1024 * 1024;

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    const form = await req.formData();
    const token = form.get('token')?.toString()?.trim() ?? '';
    const fileEntry = form.get('file');
    const aiExtracted = form.get('ai_extracted')?.toString() === 'true';

    if (!token) return json({ error: 'Missing token' }, 400);
    // access_token is a uuid column — a non-uuid would blow up the query as a cast error rather
    // than reading as a bad credential, so reject the shape first.
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(token)) {
      return json({ error: 'Invalid link' }, 401);
    }
    const file = fileEntry as File | null;
    if (!file || typeof file.name !== 'string') return json({ error: 'No file uploaded' }, 400);
    if (file.size > MAX_BYTES) return json({ error: 'File is too large (max 20 MB)' }, 413);

    const admin = createClient(supabaseUrl, serviceKey);

    // The token is the credential. It must exist and still be live.
    const { data: link, error: linkErr } = await admin
      .schema('qvm_new_apps')
      .from('quotation_vendors')
      .select('quotation_vendor_id, quotation_id, vendor_id, token_expires_at')
      .eq('access_token', token)
      .maybeSingle();

    if (linkErr) return json({ error: linkErr.message }, 500);
    if (!link) return json({ error: 'Invalid link' }, 401);
    if (link.token_expires_at && new Date(link.token_expires_at).getTime() < Date.now()) {
      return json({ error: 'This link has expired' }, 401);
    }

    const safeName = file.name.replace(/[^\w.\-]+/g, '_');
    const path = `quotation-attachments/${link.quotation_id}/${link.vendor_id ?? 'v'}/${Date.now()}-${safeName}`;

    const { error: upErr } = await admin.storage
      .from('attachments')
      .upload(path, file, { upsert: false, contentType: file.type || 'application/octet-stream' });
    if (upErr) return json({ error: upErr.message }, 500);

    const { data: pub } = admin.storage.from('attachments').getPublicUrl(path);

    const { data: row, error: insErr } = await admin
      .schema('qvm_new_apps')
      .from('quotation_attachments')
      .insert({
        quotation_id: link.quotation_id,
        vendor_id: link.vendor_id,
        quotation_vendor_id: link.quotation_vendor_id,
        file_url: pub?.publicUrl ?? '',
        file_path: path,
        file_name: file.name,
        file_type: classifyAttachmentType(file.name, file.type),
        mime_type: file.type || null,
        file_size: file.size,
        ai_extracted: aiExtracted,
      })
      .select('*')
      .single();

    if (insErr) {
      // Don't leave the object behind if the row didn't land.
      await admin.storage.from('attachments').remove([path]).catch(() => {});
      return json({ error: insErr.message }, 500);
    }

    return json({ attachment: row });
  } catch (e) {
    return json({ error: (e as Error).message }, 500);
  }
});
