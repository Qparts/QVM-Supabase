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

const GEMINI_KEY = Deno.env.get('GEMINI_API_KEY') ?? '';
const DEFAULT_MODEL = Deno.env.get('GEMINI_MODEL') ?? 'gemini-flash-lite-latest';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

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

  // Said plainly and with its own code, so the screen can tell «nobody has configured this»
  // apart from «the provider refused us» — they need different people to fix them.
  if (!GEMINI_KEY) {
    return new Response(
      JSON.stringify({ error: { code: 412, status: 'AI_NOT_CONFIGURED',
        message: 'GEMINI_API_KEY is not set on the server.' } }),
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
  return new Response(text, {
    status: upstream.status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
});
