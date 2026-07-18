import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// Simple CORS helper
function buildCors(req: Request): Record<string, string> {
  const origin = req.headers.get('origin') || '*';
  const reqHeaders = req.headers.get('access-control-request-headers');
  const reqMethod = req.headers.get('access-control-request-method');
  const allowHeaders = reqHeaders && reqHeaders.length > 0
    ? reqHeaders
    : 'authorization, apikey, content-type, x-client-info';
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

// Gmail config: environment variables override these defaults
const CLIENT_ID = Deno.env.get('GMAIL_CLIENT_ID') || '981196530416-vtbvo96t94k27fnvp8bvaiaedlk1dtc4.apps.googleusercontent.com';
const CLIENT_SECRET = Deno.env.get('GMAIL_CLIENT_SECRET') || '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';
const REFRESH_TOKEN = Deno.env.get('GMAIL_REFRESH_TOKEN') || '1//0479tTV2bSIuNCgYIARAAGAQSNwF-L9Ir8iQ5x_7ol2lcoCJT7bz2xxIQ3YLBF-xdZGiD0gP2FTVWHLr0A_9GyZjWA6uCGUKbcWA';
const EMAIL_FROM = Deno.env.get('GMAIL_FROM_EMAIL') || 'ahmed2012ramadan@gmail.com';

async function getAccessToken() {
  if (!CLIENT_ID || !CLIENT_SECRET || !REFRESH_TOKEN) {
    throw new Error('Missing Gmail OAuth configuration');
  }
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
      refresh_token: REFRESH_TOKEN,
      grant_type: 'refresh_token',
    }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error(`Gmail token error: ${res.status} ${JSON.stringify(data)}`);
  return data.access_token as string;
}

// Build raw email (RFC 2822) and base64url encode
function buildEmail(to: string, subject: string, html: string) {
  if (!EMAIL_FROM) throw new Error('EMAIL_FROM is not configured');
  const email = [
    `From: ${EMAIL_FROM}`,
    `To: ${to}`,
    `Subject: ${subject}`,
    'Content-Type: text/html; charset=utf-8',
    '',
    html,
  ].join('\n');

  // deno-lint-ignore no-explicit-any
  const raw = (globalThis as any).btoa(unescape(encodeURIComponent(email)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
  return raw;
}

serve(async (req) => {
  const cors = buildCors(req);
  if (req.method === 'OPTIONS') {
    return new Response(null, { status: 204, headers: { ...cors } });
  }

  try {
    const { to, subject, body } = await req.json();
    if (!to || !subject || !body) {
      return new Response(JSON.stringify({ error: 'Missing to, subject, or body' }), { status: 400, headers: { ...cors, 'Content-Type': 'application/json' } });
    }

    const accessToken = await getAccessToken();
    const raw = buildEmail(String(to), String(subject), String(body));
    const gmailRes = await fetch('https://gmail.googleapis.com/gmail/v1/users/me/messages/send', {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ raw }),
    });
    const data = await gmailRes.json();
    const status = gmailRes.ok ? 200 : gmailRes.status;
    return new Response(JSON.stringify(data), {
      status: 200,
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (err: any) {
    console.error('email_delivery_note error:', err);
    return new Response(JSON.stringify({ error: err?.message || 'Unexpected error' }), {
      status: 500,
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  }
});
