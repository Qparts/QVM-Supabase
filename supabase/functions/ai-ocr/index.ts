// Reading invoices with Gemini, without putting the key in the browser.
//
// The key used to be `VITE_GEMINI_API_KEY`, inlined into the client bundle at build time —
// the file that did it said so itself: «it is therefore visible in the browser. This is
// acceptable for a prototype ONLY.» Anyone who opened the site could take the key and spend
// the account's credit, and there is no way to tell from the outside whether that happened.
//
// This is the whole fix: the browser sends the page and the prompt, this function adds the
// key, and the key never leaves the server. It is a thin proxy on purpose — the request body
// and the response are Gemini's own, unchanged, so the parsing, the schema, the usage
// accounting and the error classification on the client all keep working exactly as they did.

const DEFAULT_MODEL = Deno.env.get('GEMINI_MODEL') ?? 'gemini-flash-lite-latest';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

/**
 * The key, from the database rather than the deploy environment.
 *
 * An Edge Function secret would also keep it off the client, but only a project admin can
 * change one — and rotating an AI key is an operations job, not a deploy. It is stored in
 * service_credentials, which no RPC reads back and which only this role can select.
 *
 * The environment variable still wins if it is set, so an existing deployment keeps working
 * and nothing has to be migrated in a particular order.
 */
async function geminiKey(): Promise<string> {
  const fromEnv = Deno.env.get('GEMINI_API_KEY');
  if (fromEnv) return fromEnv;
  const res = await fetch(
    `${SUPABASE_URL}/rest/v1/service_credentials?service=eq.gemini&select=api_key,is_active`,
    { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
                 'Accept-Profile': 'qvm_new_apps' } },
  );
  if (!res.ok) return '';
  const rows = await res.json().catch(() => []);
  const row = Array.isArray(rows) ? rows[0] : null;
  return row?.is_active === false ? '' : (row?.api_key ?? '');
}

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

/**
 * Only a signed-in user may spend the account's credit. Checked against the caller's own JWT
 * with the anon key — this function does not need, and must not use, the service role.
 */
async function callerIsSignedIn(req: Request): Promise<boolean> {
  const auth = req.headers.get('Authorization') ?? '';
  if (!auth.startsWith('Bearer ')) return false;
  const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { Authorization: auth, apikey: ANON_KEY },
  });
  return res.ok;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  if (req.method !== 'POST') {
    return new Response(JSON.stringify({ error: { code: 405, message: 'POST only' } }), {
      status: 405, headers: { ...cors, 'Content-Type': 'application/json' },
    });
  }

  if (!(await callerIsSignedIn(req))) {
    return new Response(JSON.stringify({ error: { code: 401, message: 'unauthorized' } }), {
      status: 401, headers: { ...cors, 'Content-Type': 'application/json' },
    });
  }

  const GEMINI_KEY = await geminiKey();

  // Said plainly and with its own code, so the screen can tell «nobody has configured this»
  // apart from «the provider refused us» — they need different people to fix them.
  if (!GEMINI_KEY) {
    return new Response(
      JSON.stringify({ error: { code: 412, status: 'AI_NOT_CONFIGURED',
        message: 'No Gemini key is configured on the server.' } }),
      { status: 412, headers: { ...cors, 'Content-Type': 'application/json' } },
    );
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: { code: 400, message: 'bad json' } }), {
      status: 400, headers: { ...cors, 'Content-Type': 'application/json' },
    });
  }

  // The model is the client's to choose only from a name; the key and the host are not.
  const model = String((payload.model as string) || DEFAULT_MODEL).replace(/[^A-Za-z0-9._-]/g, '');
  const body = payload.body ?? payload;

  const upstream = await fetch(
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_KEY}`,
    {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    },
  );

  // Passed through verbatim, status included. The client already knows how to read a Gemini
  // success and how to classify a Gemini failure; rewriting either here would mean two
  // places that have to agree about what «out of credit» looks like.
  const text = await upstream.text();

  // What actually happened when we called the provider, so a screen can say «worked at
  // 14:32» or «out of credit» rather than only «a key is present».
  fetch(`${SUPABASE_URL}/rest/v1/rpc/service_credential_record_test`, {
    method: 'POST',
    headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`,
               'Content-Type': 'application/json', 'Content-Profile': 'qvm_new_apps' },
    body: JSON.stringify({
      p_service: 'gemini', p_ok: upstream.ok,
      p_note: upstream.ok ? `HTTP ${upstream.status}` : text.slice(0, 300),
    }),
  }).catch(() => { /* telemetry must never break the call it describes */ });

  return new Response(text, {
    status: upstream.status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
});
