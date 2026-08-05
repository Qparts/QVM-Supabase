// Sends a qvm_new_apps.notifications row to every active device_tokens row of its resolved
// recipient set, via Firebase Cloud Messaging's HTTP v1 API. Triggered asynchronously (via
// pg_net) by send_notification_to_all/send_notification_to_user right after they insert the
// notification row — this function does the actual outbound FCM calls and logs one
// notification_deliveries row per token, mirroring the appsheet_sync_logs/webhook_logs pattern
// used elsewhere in this codebase.
//
// Auth: FCM HTTP v1 requires an OAuth2 access token minted from a Firebase service account, not
// a static server key (Google deprecated the legacy server-key API). We implement the
// JWT-bearer exchange ourselves with Deno's WebCrypto (RS256) rather than pulling in the
// firebase-admin SDK, matching this repo's convention of dependency-light edge functions.
//
// Requires these secrets (`supabase secrets set`):
//   FIREBASE_PROJECT_ID       - Firebase project id
//   FIREBASE_CLIENT_EMAIL     - service account client_email
//   FIREBASE_PRIVATE_KEY      - service account private_key (PEM, \n-escaped is fine)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const FIREBASE_PROJECT_ID = Deno.env.get("FIREBASE_PROJECT_ID")!;
const FIREBASE_CLIENT_EMAIL = Deno.env.get("FIREBASE_CLIENT_EMAIL")!;
const FIREBASE_PRIVATE_KEY = (Deno.env.get("FIREBASE_PRIVATE_KEY") ?? "").replace(/\\n/g, "\n");

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
).schema("qvm_new_apps");

function base64url(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let str = "";
  for (const b of arr) str += String.fromCharCode(b);
  return btoa(str).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function importPrivateKey(pem: string): Promise<CryptoKey> {
  const body = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

// Exchanges the service account's key for a short-lived OAuth2 access token scoped to FCM,
// via the standard Google JWT-bearer grant (RFC 7523) — no refresh/session state to manage,
// a fresh token is minted on every cold invocation of this function.
async function getFcmAccessToken(): Promise<string> {
  const key = await importPrivateKey(FIREBASE_PRIVATE_KEY);
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: FIREBASE_CLIENT_EMAIL,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };
  const unsigned = `${base64url(new TextEncoder().encode(JSON.stringify(header)))}.${
    base64url(new TextEncoder().encode(JSON.stringify(claims)))
  }`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(unsigned),
  );
  const jwt = `${unsigned}.${base64url(signature)}`;

  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  if (!res.ok) throw new Error(`Failed to mint FCM access token: ${res.status} ${await res.text()}`);
  const json = await res.json();
  return json.access_token as string;
}

async function sendToToken(
  accessToken: string,
  token: string,
  title: string,
  body: string,
  data: Record<string, unknown> | null,
): Promise<{ ok: boolean; messageId?: string; errorCode?: string; errorMessage?: string }> {
  // FCM data payloads must be flat string maps — non-string values are JSON-stringified.
  const stringData: Record<string, string> = {};
  if (data) for (const [k, v] of Object.entries(data)) stringData[k] = typeof v === "string" ? v : JSON.stringify(v);

  const res = await fetch(
    `https://fcm.googleapis.com/v1/projects/${FIREBASE_PROJECT_ID}/messages:send`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        message: {
          token,
          notification: { title, body },
          data: stringData,
        },
      }),
    },
  );
  const json = await res.json().catch(() => ({}));
  if (res.ok) return { ok: true, messageId: json.name };
  const errorCode = json?.error?.details?.find((d: any) => d.errorCode)?.errorCode ?? json?.error?.status;
  return { ok: false, errorCode, errorMessage: json?.error?.message ?? `HTTP ${res.status}` };
}

Deno.serve(async (req) => {
  try {
    const { notification_id } = await req.json();
    if (!notification_id) return new Response(JSON.stringify({ error: "notification_id is required" }), { status: 400 });

    const { data: notification, error: nErr } = await db
      .from("notifications")
      .select("id, title, body, data")
      .eq("id", notification_id)
      .single();
    if (nErr || !notification) throw new Error(`Notification ${notification_id} not found: ${nErr?.message}`);

    // A company-wide broadcast can have hundreds of recipients — sending them all in one
    // invocation risks the edge function's execution time limit. Instead, claim (and lock) just
    // one bounded batch of still-pending notification_deliveries rows, send only those, then ask
    // Postgres to fire the next hop (net.http_post, async) if any pending rows remain. Each
    // invocation's own work is bounded by BATCH_SIZE regardless of the total recipient count.
    const BATCH_SIZE = Number(Deno.env.get("NOTIFICATION_BATCH_SIZE") ?? "50");
    const { data: batch, error: claimErr } = await db.rpc("claim_notification_delivery_batch", {
      p_notification_id: notification_id,
      p_batch_size: BATCH_SIZE,
    });
    if (claimErr) throw new Error(`Failed to claim delivery batch: ${claimErr.message}`);

    if (!batch || batch.length === 0) {
      return new Response(JSON.stringify({ status: "success", sent: 0, failed: 0, message: "Nothing pending" }));
    }

    let sent = 0;
    let failed = 0;
    // Claiming a batch flips those rows to 'sending' — if anything below throws (e.g. the FCM
    // credential exchange itself fails), those rows must not be left stuck in 'sending' forever,
    // and the queue must still advance past this batch rather than stalling on it permanently.
    // So this whole section fails soft: mark the claimed batch failed and keep going to the
    // next-batch trigger, instead of letting an exception skip straight to the outer catch.
    try {
      const accessToken = await getFcmAccessToken();
      for (const item of batch as { delivery_id: number; device_token_id: number; token: string }[]) {
        const result = await sendToToken(accessToken, item.token, notification.title, notification.body, notification.data);
        if (result.ok) {
          sent++;
          await db.from("notification_deliveries").update({
            status: "sent",
            fcm_message_id: result.messageId ?? null,
          }).eq("id", item.delivery_id);
        } else {
          failed++;
          await db.from("notification_deliveries").update({
            status: "failed",
            error_message: `${result.errorCode ?? "UNKNOWN"}: ${result.errorMessage ?? ""}`,
          }).eq("id", item.delivery_id);
          // UNREGISTERED = the token no longer exists on FCM's side (app uninstalled, token
          // rotated, etc.) - deactivate it so future sends stop wasting a call on it.
          if (result.errorCode === "UNREGISTERED" || result.errorCode === "NOT_FOUND") {
            await db.from("device_tokens").update({ is_active: false }).eq("id", item.device_token_id);
          }
        }
      }
    } catch (sendErr) {
      const ids = (batch as { delivery_id: number }[]).map((b) => b.delivery_id);
      const { error: markErr } = await db.from("notification_deliveries")
        .update({ status: "failed", error_message: `SEND_ERROR: ${String(sendErr)}` })
        .in("id", ids)
        .eq("status", "sending");
      if (markErr) console.error("Failed to mark batch failed:", markErr.message);
      failed += ids.length - sent;
    }

    // Cheap check-and-fire: only queues another invocation if this batch didn't drain the queue.
    const { error: triggerErr } = await db.rpc("trigger_next_notification_batch", { p_notification_id: notification_id });
    if (triggerErr) console.error("Failed to trigger next batch:", triggerErr.message);

    return new Response(JSON.stringify({ status: "success", sent, failed }));
  } catch (e) {
    return new Response(JSON.stringify({ status: "error", message: String(e) }), { status: 500 });
  }
});
