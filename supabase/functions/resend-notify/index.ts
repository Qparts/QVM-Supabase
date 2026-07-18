// Central email sender (Resend). Reads RESEND_API_KEY + RESEND_FROM from env — the
// key is NEVER hardcoded. Outlook (send-email) is kept but no longer used as primary.
//
// POST body: { to: string | string[], subject: string, html: string, from?: string, reply_to?: string }
import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") || Deno.env.get("Resend") || "";
    if (!RESEND_API_KEY) return json({ error: "RESEND_API_KEY is not configured" }, 500);
    const DEFAULT_FROM = Deno.env.get("RESEND_FROM") || "QVM Parts <quotations@qparts.store>";

    const body = await req.json().catch(() => ({}));
    const to = body?.to;
    const subject = String(body?.subject || "").trim();
    const html = String(body?.html || "").trim();
    const from = String(body?.from || DEFAULT_FROM).trim();
    const reply_to = body?.reply_to ? String(body.reply_to).trim() : undefined;

    const recipients = Array.isArray(to) ? to.filter(Boolean) : (to ? [String(to)] : []);
    if (recipients.length === 0 || !subject || !html) {
      return json({ error: "Required: to, subject, html" }, 400);
    }

    const payload: Record<string, unknown> = { from, to: recipients, subject, html };
    if (reply_to) payload.reply_to = reply_to;

    const resp = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Authorization": `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const data = await resp.json().catch(() => ({}));
    if (!resp.ok) return json({ error: "resend_failed", status: resp.status, detail: data }, 502);

    return json({ success: true, id: (data as any)?.id ?? null, provider: "resend" }, 200);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
