// QNEW-124 S-2 / QQ2-79 — the only place a carrier key is ever read.
//
// Everything the app needs from Mrsool goes through here: test the connection, price a
// shipment, create one, cancel it, fetch its air waybill, and receive the status webhooks.
//
// The token never reaches a browser. The app calls this function with the caller's own JWT;
// this function checks that caller is on the Qparts team, then reads the carrier's key with
// the service role and talks to Mrsool itself. A key that a client can fetch is a key that
// has left the server, whatever the UI does with it afterwards.
//
// API: https://logistics.staging.mrsool.co/api/docs — LaaS v1.

import { createClient } from 'jsr:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type, x-mrsool-signature',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });

const ok = (data: unknown) => json({ status: true, message: 'ok', data });
const fail = (message: string, status = 400) => json({ status: false, message, data: null }, status);

/** service_role client — reads credentials and writes results. Never returned to a caller. */
const admin = () => createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

type Cred = { api_base_url: string; api_token: string; environment: string; webhook_secret: string | null };

/**
 * The active credential for a carrier. `is_active` decides which environment is live, so a
 * shipment can never be created in sandbox and then tracked against production.
 */
async function credentialFor(carrierId: number): Promise<Cred | null> {
  const db = admin().schema('qvm_new_apps');
  const { data } = await db
    .from('carrier_credentials')
    .select('api_base_url, api_token, environment, webhook_secret')
    .eq('carrier_id', carrierId)
    .eq('is_active', true)
    .maybeSingle();
  if (data?.api_token) return data as Cred;

  // Nothing marked active yet — fall back to the single configured row, so a workspace that
  // has entered exactly one key works without also having to understand environments.
  const { data: any1 } = await db
    .from('carrier_credentials')
    .select('api_base_url, api_token, environment, webhook_secret')
    .not('api_token', 'is', null)
    .eq('carrier_id', carrierId)
    .limit(1)
    .maybeSingle();
  return (any1 as Cred) ?? null;
}

async function mrsool(cred: Cred, path: string, init: RequestInit = {}) {
  const res = await fetch(`${cred.api_base_url.replace(/\/$/, '')}${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${cred.api_token}`,
      'Content-Type': 'application/json',
      Accept: 'application/json',
      ...(init.headers ?? {}),
    },
  });
  const text = await res.text();
  let body: unknown = text;
  try { body = JSON.parse(text); } catch { /* carrier returned prose; keep it as it came */ }
  return { okHttp: res.ok, status: res.status, body };
}

/** Records every carrier call, successful or not, in the log the app already has a page for. */
async function logCall(trigger: string, refId: string | null, url: string, payload: unknown,
                       status: number, body: unknown) {
  try {
    await admin().schema('qvm_new_apps').from('webhook_logs').insert({
      trigger_type: trigger,
      reference_id: refId,
      request_url: url,
      request_payload: payload as Record<string, unknown>,
      response_status: status,
      response_body: typeof body === 'string' ? body : JSON.stringify(body),
      status: status >= 200 && status < 300 ? 'success' : 'failed',
    });
  } catch { /* logging must never be the reason a shipment fails to dispatch */ }
}

/** The caller must be a signed-in Qparts team member. Checked against their own JWT. */
async function callerIsTeam(req: Request): Promise<boolean> {
  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return false;
  const asUser = createClient(SUPABASE_URL, Deno.env.get('SUPABASE_ANON_KEY')!, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });
  const { data, error } = await asUser.schema('qvm_new_apps').rpc('is_qparts_team');
  return !error && data === true;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  const url = new URL(req.url);
  const action = url.searchParams.get('action') ?? '';

  // ---------------------------------------------------------------- webhook
  // Mrsool posts here. No user JWT: authenticity comes from the shared secret, and an
  // unsigned post is rejected and logged rather than silently ignored.
  if (action === 'webhook') {
    const raw = await req.text();
    let payload: Record<string, unknown> = {};
    try { payload = JSON.parse(raw); } catch { /* handled as a bad body below */ }

    const db = admin().schema('qvm_new_apps');
    const { data: creds } = await db
      .from('carrier_credentials')
      .select('carrier_id, webhook_secret')
      .not('webhook_secret', 'is', null);

    const sent = req.headers.get('x-mrsool-signature') ?? url.searchParams.get('secret') ?? '';
    const anyMatch = (creds ?? []).some((c: { webhook_secret: string }) => c.webhook_secret === sent);

    if (!anyMatch) {
      await logCall('mrsool_webhook', null, url.pathname, { raw: raw.slice(0, 2000) }, 401, 'bad signature');
      return fail('unauthorized', 401);
    }

    // Mrsool's own field names; the id is what we stored as tracking_ref on dispatch.
    const order = (payload.order ?? payload.data ?? payload) as Record<string, unknown>;
    const ref = String(order.id ?? order.order_id ?? payload.order_id ?? '');
    const status = String(order.status ?? payload.status ?? '');

    if (!ref || !status) {
      await logCall('mrsool_webhook', ref || null, url.pathname, payload, 422, 'missing id or status');
      return fail('missing order id or status', 422);
    }

    const { data: applied } = await db.rpc('carrier_status_apply', {
      p_tracking_ref: ref, p_carrier_status: status, p_payload: payload,
    });
    await logCall('mrsool_webhook', ref, url.pathname, payload, 200, applied);
    return ok(applied);
  }

  // ------------------------------------------------------- everything else
  if (!(await callerIsTeam(req))) return fail('forbidden', 403);

  let body: Record<string, unknown> = {};
  if (req.method === 'POST') { try { body = await req.json(); } catch { /* empty body is fine */ } }

  const carrierId = Number(body.carrier_id ?? url.searchParams.get('carrier_id') ?? 0);
  if (!carrierId) return fail('carrier_id is required');

  const cred = await credentialFor(carrierId);
  if (!cred) return fail('لم تُضبط بيانات الاعتماد لهذه الشركة بعد', 412);

  const db = admin().schema('qvm_new_apps');

  switch (action) {
    // A cheap authenticated call: if the key is wrong Mrsool answers 401, which is exactly
    // what the settings screen needs to know.
    case 'test': {
      const r = await mrsool(cred, '/laas/api/v1/webhook_logs');
      const good = r.status !== 401 && r.status !== 403;
      await db.from('carrier_credentials').update({
        last_test_at: new Date().toISOString(),
        last_test_ok: good,
        last_test_note: good ? `HTTP ${r.status} — ${cred.environment}` : `HTTP ${r.status} — رُفض المفتاح`,
      }).eq('carrier_id', carrierId).eq('environment', cred.environment);
      await logCall('mrsool_test', null, '/laas/api/v1/webhook_logs', null, r.status, r.body);
      return good
        ? ok({ environment: cred.environment, http: r.status })
        : fail(`المفتاح مرفوض من مرسول (HTTP ${r.status})`, 400);
    }

    case 'price': {
      const shipmentId = Number(body.shipment_id ?? 0);
      if (!shipmentId) return fail('shipment_id is required');
      const { data: p } = await db.rpc('shipment_carrier_payload', { p_shipment_id: shipmentId });
      const pickup = (p as Record<string, any>)?.pickup ?? {};
      const dropoff = (p as Record<string, any>)?.dropoff ?? {};

      // Named plainly, because this is the commonest reason a dispatch cannot proceed and
      // «invalid input» from the carrier tells nobody what to go and fix.
      if (!pickup.latitude || !pickup.longitude || !dropoff.latitude || !dropoff.longitude) {
        return fail('مرسول يحتاج إحداثيات للطرفين — أضِف خط الطول والعرض للعنوان أو الفرع', 422);
      }

      const payload = {
        pickup: { latitude: String(pickup.latitude), longitude: String(pickup.longitude) },
        dropoff: { latitude: String(dropoff.latitude), longitude: String(dropoff.longitude) },
      };
      const r = await mrsool(cred, '/laas/api/v1/orders/calculate_price', {
        method: 'POST', body: JSON.stringify(payload),
      });
      await logCall('mrsool_price', String(shipmentId), '/laas/api/v1/orders/calculate_price',
                    payload, r.status, r.body);
      if (!r.okHttp) return fail(`تعذّر حساب السعر (HTTP ${r.status})`, 400);
      const price = (r.body as Record<string, unknown>)?.data ?? r.body;
      return ok({ price, currency: 'SAR' });
    }

    case 'create': {
      const shipmentId = Number(body.shipment_id ?? 0);
      if (!shipmentId) return fail('shipment_id is required');
      const { data: p } = await db.rpc('shipment_carrier_payload', { p_shipment_id: shipmentId });
      const s = p as Record<string, any>;

      if (s?.tracking_ref) return fail('هذه الشحنة مُرسلة إلى مرسول بالفعل', 409);
      if (!s?.pickup?.latitude || !s?.dropoff?.latitude) {
        return fail('مرسول يحتاج إحداثيات للطرفين — أضِف خط الطول والعرض للعنوان أو الفرع', 422);
      }
      if (!s?.buyer?.phone) {
        return fail('رقم هاتف المستلم مطلوب لإنشاء شحنة مرسول', 422);
      }

      const payload = {
        pickup: s.pickup,
        dropoff: s.dropoff,
        buyer: s.buyer,
        store: s.store,
        description: s.description,
        shipment_value: s.shipment_value,
        // Our own code goes with it, so a shipment can be found from either side.
        partner_order_id: s.order_id ?? undefined,
        pickup_type: 'shop_pickup',
      };
      const r = await mrsool(cred, '/laas/api/v1/orders', {
        method: 'POST', body: JSON.stringify(payload),
      });
      await logCall('mrsool_create', String(shipmentId), '/laas/api/v1/orders', payload, r.status, r.body);
      if (!r.okHttp) return fail(`تعذّر إنشاء الشحنة لدى مرسول (HTTP ${r.status})`, 400);

      const d = ((r.body as Record<string, any>)?.data ?? r.body) as Record<string, any>;
      await db.rpc('shipment_carrier_result', {
        p_shipment_id: shipmentId,
        p_data: {
          tracking_ref: String(d?.id ?? ''),
          carrier_status: d?.status ?? null,
          payload: d ?? null,
        },
      });
      return ok({ tracking_ref: String(d?.id ?? ''), carrier_status: d?.status ?? null });
    }

    case 'cancel': {
      const ref = String(body.tracking_ref ?? '');
      if (!ref) return fail('tracking_ref is required');
      const r = await mrsool(cred, `/laas/api/v1/orders/${ref}/cancel`, { method: 'POST' });
      await logCall('mrsool_cancel', ref, `/laas/api/v1/orders/${ref}/cancel`, null, r.status, r.body);
      if (!r.okHttp) return fail(`تعذّر الإلغاء لدى مرسول (HTTP ${r.status})`, 400);
      await db.rpc('carrier_status_apply', {
        p_tracking_ref: ref, p_carrier_status: 'CANCELED', p_payload: r.body,
      });
      return ok(r.body);
    }

    case 'awb': {
      const ref = String(body.tracking_ref ?? url.searchParams.get('tracking_ref') ?? '');
      if (!ref) return fail('tracking_ref is required');
      const r = await mrsool(cred, `/laas/api/v1/orders/${ref}/air_waybill`);
      if (!r.okHttp) return fail(`تعذّر جلب بوليصة الشحن (HTTP ${r.status})`, 400);
      return ok(r.body);
    }

    // Sandbox only. Mrsool's own endpoint for driving an order through its statuses, and it
    // fires the real webhooks — which is how the whole loop gets tested without a courier.
    case 'test_status': {
      if (cred.environment !== 'sandbox') return fail('متاح في البيئة التجريبية فقط', 403);
      const ref = String(body.tracking_ref ?? '');
      const next = String(body.status ?? '');
      if (!ref || !next) return fail('tracking_ref and status are required');
      const r = await mrsool(cred, `/laas/api/v1/orders/${ref}/test_status`, {
        method: 'POST', body: JSON.stringify({ status: next }),
      });
      await logCall('mrsool_test_status', ref, `/laas/api/v1/orders/${ref}/test_status`,
                    { status: next }, r.status, r.body);
      if (!r.okHttp) return fail(`تعذّر تغيير الحالة (HTTP ${r.status})`, 400);
      return ok(r.body);
    }

    // Pull rather than wait — for when a webhook was missed.
    case 'sync': {
      const ref = String(body.tracking_ref ?? '');
      if (!ref) return fail('tracking_ref is required');
      const r = await mrsool(cred, `/laas/api/v1/orders/${ref}`);
      if (!r.okHttp) return fail(`تعذّر قراءة الشحنة (HTTP ${r.status})`, 400);
      const d = ((r.body as Record<string, any>)?.data ?? r.body) as Record<string, any>;
      if (d?.status) {
        await db.rpc('carrier_status_apply', {
          p_tracking_ref: ref, p_carrier_status: String(d.status), p_payload: d,
        });
      }
      return ok(d);
    }

    default:
      return fail(`unknown action: ${action || '(none)'}`, 404);
  }
});
