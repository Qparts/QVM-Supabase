import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// CORS helper
function buildCors(req: Request): Record<string, string> {
  const origin = req.headers.get('origin') || '*';
  const reqHeaders = req.headers.get('access-control-request-headers');
  const reqMethod = req.headers.get('access-control-request-method');
  const allowHeaders = reqHeaders && reqHeaders.length > 0 ? reqHeaders : 'authorization, apikey, content-type, x-client-info';
  const allowMethods = reqMethod && reqMethod.length > 0 ? reqMethod : 'POST, OPTIONS';
  return {
    'Access-Control-Allow-Origin': origin,
    'Vary': 'Origin',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Allow-Headers': allowHeaders,
    'Access-Control-Allow-Methods': allowMethods,
    'Access-Control-Max-Age': '86400',
  };
}

type Attachment = { name: string; contentType: string; contentBase64: string };
type MailPayload = {
  to: string | string[];
  subject: string;
  body: string;
  // Optional: for JSON requests
  attachments?: { name: string; type: string; base64: string }[];
  file_url?: string;
  order_number?: string;
  confirmed_order_id?: number;
};
async function refreshAccessToken() {
  const OUTLOOK_CLIENT_ID = Deno.env.get('OUTLOOK_CLIENT_ID') || '61100bdd-46c9-477b-b0c5-819bdf44071d';
  const OUTLOOK_CLIENT_SECRET = Deno.env.get('OUTLOOK_CLIENT_SECRET') || 'eXU8Q~bWWCNubGfPah93xEa~XIH7gWFgVR3AaaP~';
  const OUTLOOK_TENANT = Deno.env.get('OUTLOOK_TENANT') || 'consumers';
  const REFRESH_TOKEN = Deno.env.get('OUTLOOK_REFRESH_TOKEN') || 'M.C555_BAY.0.U.-CqHDx5iOUT!gsyI45fgkkO3fF1ndCoI6RUYoItdKXgiWdJKfkOKzyVzDJ0Lrs81qakII7Of4CH4vefC2NkSgTl6TgpnPG8xxV1yCeONosggBAWnojJr03*!GrGo0jaN918iQBMeQOBJXyiWu8wExlibtvfiS3bYw3dL4a4g27MdIEjTAK4J7tZfdd25qf6eUvBiHpH4gNXMjlLZ*68jwigKMy2q8y5pFkQXk!UWHgHX2aulM9Ec!FcgGXAIQ7!6mg!QLNOWjH4iXB*aq1k8jFvUsfaBrUMPmyvICCpyqXnXCst!IxjOCDZhL4*SGoaVnoyZFK1NA!BzFQtwhryEyRLp3j*RhhAjial8TWFLedn4mecBBdS7jOcLEoC9xPzTvRw$$';
  const OUTLOOK_USER = "almulhimauto@outlook.com";

  if (!OUTLOOK_CLIENT_ID || !OUTLOOK_CLIENT_SECRET || !REFRESH_TOKEN) {
    throw new Error('Outlook credentials are not configured');
  }
  const params = new URLSearchParams();
  params.append("client_id", OUTLOOK_CLIENT_ID);
  params.append("client_secret", OUTLOOK_CLIENT_SECRET);
  params.append("grant_type", "refresh_token");
  params.append("refresh_token", REFRESH_TOKEN);
  const res = await fetch(`https://login.microsoftonline.com/${OUTLOOK_TENANT}/oauth2/v2.0/token`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded"
    },
    body: params
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`Failed to refresh token: ${JSON.stringify(data)}`);
  return data.access_token;
}
async function sendOutlookEmail(accessToken: string, senderEmail: string, to: string | string[], subject: string, content: string, attachments: Attachment[] = []) {
  const msftAttachments = attachments.map(a => ({
    "@odata.type": "#microsoft.graph.fileAttachment",
    name: a.name,
    contentType: a.contentType,
    contentBytes: a.contentBase64,
  }));
  const email: any = {
    message: {
      subject,
      body: {
        contentType: "HTML",
        content,
      },
      toRecipients: (Array.isArray(to) ? to : [to]).map(addr => ({ emailAddress: { address: String(addr) } })),
      attachments: msftAttachments,
    },
    saveToSentItems: true
  };
  const OUTLOOK_USER = Deno.env.get('OUTLOOK_USER') || senderEmail;
  const res = await fetch(`https://graph.microsoft.com/v1.0/users/${OUTLOOK_USER}/sendMail`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify(email)
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`Failed to send email: ${text}`);
  }
  return true;
}
serve(async (req) => {
  const cors = buildCors(req);
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: { ...cors } });
  }
  try {
    // Parse body (multipart or JSON)
    let payload: MailPayload;
    let attachments: Attachment[] = [];
    if ((req.headers.get('content-type') || '').includes('multipart/form-data')) {
      const formData = await req.formData();
      const to = formData.get('to');
      const subject = formData.get('subject');
      const body = formData.get('body');
      const order_number = formData.get('order_number');
      const confirmed_order_id = formData.get('confirmed_order_id');
      if (!subject || !body) throw new Error('Missing subject/body');
      payload = {
        // @ts-ignore allow undefined
        to: to ? String(to) : undefined,
        subject: String(subject),
        body: String(body),
        order_number: order_number ? String(order_number) : undefined,
        confirmed_order_id: confirmed_order_id ? Number(confirmed_order_id) : undefined,
      } as MailPayload;
      const file = formData.get('file') as File | null;
      if (file) {
        const name = file.name || 'attachment';
        const type = (file.type || 'application/octet-stream');
        const buf = new Uint8Array(await file.arrayBuffer());
        attachments.push({ name, contentType: type, contentBase64: encodeBase64(buf) });
      }
    } else {
      payload = await req.json();
      if (!payload?.subject || !payload?.body) throw new Error('Missing subject/body');
      if (payload.attachments && Array.isArray(payload.attachments)) {
        attachments = payload.attachments.map(a => ({ name: a.name, contentType: a.type, contentBase64: a.base64 }));
      }
      if (payload.file_url && !attachments.length) {
        try {
          const fileRes = await fetch(payload.file_url);
          const ab = new Uint8Array(await fileRes.arrayBuffer());
          const ct = fileRes.headers.get('content-type') || 'application/octet-stream';
          const fn = payload.file_url.split('/').pop() || 'attachment.pdf';
          attachments.push({ name: fn, contentType: ct, contentBase64: encodeBase64(ab) });
        } catch (_) { /* ignore fetch errors, proceed without attachment */ }
      }
    }

    const OUTLOOK_SENDER = Deno.env.get('OUTLOOK_USER') || '';
    const EMAIL_FROM = Deno.env.get('EMAIL_FROM') || OUTLOOK_SENDER || '';
    const EMAIL_REPLY_TO = Deno.env.get('EMAIL_REPLY_TO') || '';
    const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') || '';

    // Resolve recipient if 'to' is not supplied but order details are
    let toResolved: string | string[] | undefined = payload.to;
    if (!toResolved && (payload.order_number || payload.confirmed_order_id)) {
      const supabaseUrl = Deno.env.get('SUPABASE_URL');
      const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
      if (!supabaseUrl || !serviceRoleKey) throw new Error('Missing Supabase env vars');
      const sb = createClient(supabaseUrl, serviceRoleKey);
      if (payload.order_number) {
        const { data, error } = await sb.rpc('get_service_advisor_email_by_order', { p_order_number: payload.order_number });
        if (error) throw new Error(error.message || 'Failed to resolve recipient by order_number');
        toResolved = data ?? undefined;
      } else if (payload.confirmed_order_id) {
        const { data, error } = await sb.rpc('get_service_advisor_email_by_confirmed_order', { p_confirmed_order_id: payload.confirmed_order_id });
        if (error) throw new Error(error.message || 'Failed to resolve recipient by confirmed_order_id');
        toResolved = data ?? undefined;
      }
    }
    if (!toResolved) throw new Error('Recipient not provided and could not be resolved');

    // Get access token (fallback to Resend immediately if refresh fails)
    let token: string;
    try {
      token = await refreshAccessToken();
    } catch (err) {
      if (RESEND_API_KEY) {
        const resp = await fetch('https://api.resend.com/emails', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${RESEND_API_KEY}`,
            'Content-Type': 'application/json',
          },
          body: JSON.stringify({
            from: EMAIL_FROM || 'No Reply <noreply@example.com>',
            to: Array.isArray(toResolved) ? toResolved : [toResolved],
            subject: payload.subject,
            html: payload.body,
            reply_to: EMAIL_REPLY_TO ? [EMAIL_REPLY_TO] : undefined,
            attachments: attachments.length ? attachments.map(a => ({ filename: a.name, content: a.contentBase64 })) : undefined,
          }),
        });
        if (!resp.ok) {
          const t = await resp.text().catch(() => '');
          throw new Error(`Resend error: ${resp.status} ${t}`);
        }
        return new Response(JSON.stringify({ success: true, provider: 'resend' }), { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } });
      }
      throw err;
    }

    // Send with retry/backoff for throttling/transient errors
    const maxAttempts = 3;
    let attempt = 0;
    while (true) {
      try {
        await sendOutlookEmail(token, EMAIL_FROM || OUTLOOK_SENDER, toResolved, payload.subject, payload.body, attachments);
        break; // success
      } catch (err: any) {
        attempt++;
        const msg = String(err?.message || '');
        // If token might be expired/invalid, refresh once
        if (msg.includes('InvalidAuthenticationToken') || msg.includes('401') || msg.includes('invalid_grant')) {
          if (attempt <= maxAttempts) {
            try { token = await refreshAccessToken(); } catch {}
          }
        }
        // Retry on throttling or 5xx
        if (attempt < maxAttempts && (msg.includes('429') || msg.includes('TooManyRequests') || msg.includes('5xx') || msg.includes('503') || msg.includes('TransientError'))) {
          const backoff = 500 * Math.pow(2, attempt - 1);
          await new Promise(r => setTimeout(r, backoff));
          continue;
        }
        // Fallback to Resend if configured
        if (RESEND_API_KEY) {
          const resp = await fetch('https://api.resend.com/emails', {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${RESEND_API_KEY}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({
              from: EMAIL_FROM || 'No Reply <noreply@example.com>',
              to: Array.isArray(toResolved) ? toResolved : [toResolved],
              subject: payload.subject,
              html: payload.body,
              reply_to: EMAIL_REPLY_TO ? [EMAIL_REPLY_TO] : undefined,
              attachments: attachments.length ? attachments.map(a => ({ filename: a.name, content: a.contentBase64 })) : undefined,
            }),
          });
          if (!resp.ok) {
            const t = await resp.text().catch(() => '');
            throw new Error(`Resend error: ${resp.status} ${t}`);
          }
          break; // fallback success
        }
        throw err; // surface last error
      }
    }

    return new Response(JSON.stringify({ success: true }), { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } });
  } catch (err: any) {
    console.error('send-email error:', err?.message || err);
    return new Response(JSON.stringify({ success: false, error: err?.message || 'Unexpected error' }), { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } });
  }
});
