// wa-bridge — the only door between the WhatsApp gateway on the VPS and the DB.
//
// GOWA lives on 127.0.0.1:8081 inside the VPS and is never exposed to the
// internet. A small bridge process next to it talks to this function, which is
// the only thing holding a service-role key. The bridge authenticates with a
// shared secret whose SHA-256 is kept in qvm_new_apps.wa_settings, so rotating
// it is an UPDATE, not a redeploy, and the plaintext exists only in the VPS
// env file.
//
// Routes (all POST, action in the body):
//   inbound   -> wa_ingest_message      (a vendor messaged us)
//   outbound  -> wa_ingest_outbound     (we replied from the phone, not the panel)
//   claim     -> wa_claim_outbox        (bridge asks for work)
//   complete  -> wa_complete_outbox     (bridge reports the send result)
//   delivery  -> wa_update_delivery     (WhatsApp ack/read receipt)
//   upload    -> signed URL so the bridge can push received media straight into
//                Storage without the bytes ever passing through this function
//   download  -> signed URL so the bridge can fetch media we are sending out
//   purge     -> delete a prefix's media; Storage forbids this from SQL, and
//                clearing a channel would otherwise leave its files orphaned
//   avatars_pending / set_avatar -> contact profile pictures
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.0';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false },
  db: { schema: 'qvm_new_apps' },
});

const MEDIA_BUCKET = 'whatsapp-media';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type, x-bridge-secret',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

// Length-independent, timing-safe-ish comparison of two hex digests.
function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

let cachedHash: { value: string; at: number } | null = null;

async function expectedHash(): Promise<string | null> {
  // 60s cache: the secret changes about never, and this runs on every poll.
  if (cachedHash && Date.now() - cachedHash.at < 60_000) return cachedHash.value;
  const { data, error } = await admin
    .from('wa_settings')
    .select('value')
    .eq('key', 'bridge_secret_sha256')
    .maybeSingle();
  if (error || !data?.value) return null;
  cachedHash = { value: String(data.value).trim().toLowerCase(), at: Date.now() };
  return cachedHash.value;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ status: false, message: 'method not allowed' }, 405);

  const presented = req.headers.get('x-bridge-secret') ?? '';
  if (!presented) return json({ status: false, message: 'unauthorized' }, 401);

  const expected = await expectedHash();
  if (!expected) return json({ status: false, message: 'bridge secret not configured' }, 503);
  if (!safeEqual(await sha256Hex(presented), expected)) {
    return json({ status: false, message: 'unauthorized' }, 401);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ status: false, message: 'invalid json' }, 400);
  }

  const action = String(payload.action ?? '');

  try {
    switch (action) {
      case 'ping':
        return json({ status: true, message: 'pong' });

      case 'inbound': {
        const { data, error } = await admin.rpc('wa_ingest_message', {
          p_wa_message_id: payload.wa_message_id ?? null,
          p_jid: payload.jid ?? null,
          p_phone: payload.phone ?? null,
          p_display_name: payload.display_name ?? null,
          p_body: payload.body ?? null,
          p_media_url: payload.media_url ?? null,
          p_media_mime: payload.media_mime ?? null,
          p_media_kind: payload.media_kind ?? null,
          p_media_name: payload.media_name ?? null,
          p_wa_timestamp: payload.wa_timestamp ?? null,
          p_raw: payload.raw ?? null,
          p_chat_type: payload.chat_type ?? 'individual',
          p_sender_jid: payload.sender_jid ?? null,
          p_sender_name: payload.sender_name ?? null,
          p_reply_to_wa_id: payload.reply_to_wa_id ?? null,
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'outbound': {
        // A message the team sent from the phone itself, or the echo of one we
        // sent from the panel — the RPC adopts the latter instead of double-logging.
        const { data, error } = await admin.rpc('wa_ingest_outbound', {
          p_wa_message_id: payload.wa_message_id ?? null,
          p_jid: payload.jid ?? null,
          p_phone: payload.phone ?? null,
          p_body: payload.body ?? null,
          p_media_url: payload.media_url ?? null,
          p_media_mime: payload.media_mime ?? null,
          p_media_kind: payload.media_kind ?? null,
          p_media_name: payload.media_name ?? null,
          p_wa_timestamp: payload.wa_timestamp ?? null,
          p_raw: payload.raw ?? null,
          p_reply_to_wa_id: payload.reply_to_wa_id ?? null,
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'typing': {
        const { data, error } = await admin.rpc('wa_set_typing', {
          p_phone: payload.phone ?? null,
          p_seconds: Number(payload.seconds ?? 12),
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'claim': {
        const { data, error } = await admin.rpc('wa_claim_outbox', {
          p_limit: Number(payload.limit ?? 10),
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'complete': {
        const { data, error } = await admin.rpc('wa_complete_outbox', {
          p_outbox_id: Number(payload.outbox_id),
          p_ok: Boolean(payload.ok),
          p_wa_message_id: payload.wa_message_id ?? null,
          p_error: payload.error ?? null,
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'delivery': {
        const { data, error } = await admin.rpc('wa_update_delivery', {
          p_wa_message_id: payload.wa_message_id ?? null,
          p_status: payload.status ?? null,
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'device_state': {
        const { data, error } = await admin.rpc('wa_set_device_state', {
          p_device_id: payload.device_id ?? null,
          p_state: payload.state ?? null,
          p_jid: payload.jid ?? null,
          p_qr_png: payload.qr_png ?? null,
          p_qr_ttl_seconds: payload.qr_ttl_seconds ?? null,
          p_error: payload.error ?? null,
          p_clear_pair_request: Boolean(payload.clear_pair_request),
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'assignees': {
        const { data, error } = await admin.rpc('wa_list_assignees');
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'avatars_pending': {
        const { data, error } = await admin.rpc('wa_avatars_pending', {
          p_limit: Number(payload.limit ?? 5),
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'set_avatar': {
        const { data, error } = await admin.rpc('wa_set_avatar', {
          p_wa_contact_id: Number(payload.wa_contact_id),
          p_avatar_path: payload.avatar_path ?? null,
          p_avatar_id: payload.avatar_id ?? null,
          p_push_name: payload.push_name ?? null,
        });
        if (error) return json({ status: false, message: error.message }, 500);
        return json(data);
      }

      case 'upload': {
        // Vendors send photos of parts constantly, so media is a first-class
        // path, not an afterthought. The bridge asks for a one-shot upload URL
        // and PUTs the bytes directly to Storage.
        const path = String(payload.path ?? '').replace(/^\/+/, '');
        if (!path) return json({ status: false, message: 'path required' }, 400);
        // Avatars are re-fetched weekly, so their upload must overwrite.
        const { data, error } = await admin.storage
          .from(MEDIA_BUCKET)
          .createSignedUploadUrl(path, { upsert: Boolean(payload.upsert) });
        if (error) return json({ status: false, message: error.message }, 500);
        return json({ status: true, message: 'ok', data: { ...data, path } });
      }

      case 'purge': {
        // Storage blocks deletion from SQL to stop orphaned objects, so clearing
        // a channel's files has to come through here, where the service key is.
        // Scoped to a prefix and nothing else — there is no "delete everything".
        const prefix = String(payload.prefix ?? '').replace(/^\/+/, '');
        if (!prefix || prefix.includes('..')) {
          return json({ status: false, message: 'a prefix is required' }, 400);
        }
        // Media is filed per account (email/<account>/<message>), so a flat list
        // returns folders, not files. Walk down; Storage marks a folder by
        // returning a null id.
        let removed = 0;
        const walk = async (dir: string): Promise<string | null> => {
          // Always re-list from the start: deleting a page shifts everything
          // after it forward, so advancing an offset would skip that many files.
          for (;;) {
            const { data: listed, error: listErr } = await admin.storage
              .from(MEDIA_BUCKET).list(dir, { limit: 100, offset: 0 });
            if (listErr) return listErr.message;
            const files = (listed ?? []).filter((f) => f.id).map((f) => `${dir}/${f.name}`);
            if (!files.length) break;   // only folders left here
            const { error: delErr } = await admin.storage.from(MEDIA_BUCKET).remove(files);
            if (delErr) return delErr.message;
            removed += files.length;
          }
          const { data: rest, error: restErr } = await admin.storage
            .from(MEDIA_BUCKET).list(dir, { limit: 100, offset: 0 });
          if (restErr) return restErr.message;
          for (const folder of (rest ?? []).filter((f) => !f.id)) {
            const failed = await walk(`${dir}/${folder.name}`);
            if (failed) return failed;
          }
          return null;
        };
        const failure = await walk(prefix.replace(/\/+$/, ''));
        if (failure) return json({ status: false, message: failure }, 500);
        return json({ status: true, message: 'ok', data: { removed, prefix } });
      }

      case 'download': {
        const path = String(payload.path ?? '').replace(/^\/+/, '');
        if (!path) return json({ status: false, message: 'path required' }, 400);
        const { data, error } = await admin.storage
          .from(MEDIA_BUCKET)
          .createSignedUrl(path, 600);
        if (error) return json({ status: false, message: error.message }, 500);
        return json({ status: true, message: 'ok', data });
      }

      default:
        return json({ status: false, message: `unknown action '${action}'` }, 400);
    }
  } catch (e) {
    return json({ status: false, message: String((e as Error)?.message ?? e) }, 500);
  }
});
