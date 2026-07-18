// Email OTP for registration. Two actions on POST:
//   { action: "send",   email }         -> generate a 6-digit code, store its hash, email it via Resend
//   { action: "verify", email, code }   -> check the code (expiry + attempts) and mark verified
//
// The plaintext code never leaves the server: only a salted SHA-256 hash is stored, and "send"
// returns only { success }. Uses the service role (auto-injected) to reach qvm_new_apps.email_otps.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });

const OTP_TTL_MIN = 10;
const RESEND_COOLDOWN_SEC = 45;
const MAX_ATTEMPTS = 5;
const isEmail = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);

async function hashCode(code: string, email: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`${code}:${email}`));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function genCode(): string {
  const a = new Uint32Array(1);
  crypto.getRandomValues(a);
  return String(100000 + (a[0] % 900000));
}

function otpEmailHtml(code: string): string {
  const font = "'Cairo','Segoe UI',Tahoma,Arial,sans-serif";
  const logo = "https://panel.qvm.kareemelbhrawy.com/qvm-logo.png";
  return `<!doctype html><html dir="rtl" lang="ar"><head><meta charset="utf-8"/>
  <style>@import url('https://fonts.googleapis.com/css2?family=Cairo:wght@400;700;800&display=swap');body{margin:0;background:#ffffff}</style></head>
  <body style="margin:0;background:#ffffff;font-family:${font};color:#334155">
    <div style="max-width:600px;margin:0 auto;background:#ffffff">
      <div style="height:4px;background:#0D4151"></div>
      <div style="padding:30px 44px 6px;text-align:center"><img src="${logo}" alt="QVM Parts" height="52"/></div>
      <div style="padding:10px 44px 34px">
        <h1 style="margin:8px 0 6px;font-size:20px;font-weight:800;color:#0f172a;text-align:center">رمز التحقق من بريدك</h1>
        <p style="margin:0 0 20px;text-align:center;color:#64748b;font-size:14px">استخدم الرمز التالي لإكمال تسجيلك. صالح لمدة ${OTP_TTL_MIN} دقائق.</p>
        <div style="margin:0 auto 20px;max-width:280px;background:#f8fafc;border:1px solid #e2e8f0;border-radius:14px;padding:18px;text-align:center">
          <div style="font-family:'Courier New',monospace;font-size:38px;font-weight:800;letter-spacing:10px;color:#0D4151">${code}</div>
        </div>
        <p style="margin:0;text-align:center;color:#94a3b8;font-size:12px">لو مش إنت اللي طلبت التسجيل، تجاهل هذه الرسالة.</p>
      </div>
      <div style="border-top:1px solid #eef2f5;padding:20px 44px;text-align:center">
        <div style="color:#94a3b8;font-size:12px">QVM Parts — منصة مشتريات قطع الغيار</div>
        <div style="color:#cbd5e1;font-size:11px;margin-top:4px"><a href="https://qparts.store" style="color:#94a3b8">qparts.store</a></div>
      </div>
    </div>
  </body></html>`;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY") || Deno.env.get("Resend") || "";
    const FROM = Deno.env.get("RESEND_FROM") || "QVM Parts <quotations@qparts.store>";
    const sb = createClient(SUPABASE_URL, SERVICE_KEY, { db: { schema: "qvm_new_apps" } });

    const body = await req.json().catch(() => ({}));
    const action = String(body?.action || "");
    const email = String(body?.email || "").trim().toLowerCase();
    if (!isEmail(email)) return json({ error: "invalid_email" }, 400);

    if (action === "send") {
      if (!RESEND_API_KEY) return json({ error: "email_not_configured" }, 500);

      // Rate-limit resends per email.
      const { data: existing } = await sb.from("email_otps").select("last_sent_at").eq("email", email).maybeSingle();
      if (existing?.last_sent_at) {
        const secs = (Date.now() - new Date(existing.last_sent_at).getTime()) / 1000;
        if (secs < RESEND_COOLDOWN_SEC) return json({ error: "cooldown", retry_after: Math.ceil(RESEND_COOLDOWN_SEC - secs) }, 429);
      }

      const code = genCode();
      const code_hash = await hashCode(code, email);
      const expires_at = new Date(Date.now() + OTP_TTL_MIN * 60_000).toISOString();
      const { error: upErr } = await sb.from("email_otps").upsert({
        email, code_hash, expires_at, attempts: 0, verified: false, last_sent_at: new Date().toISOString(),
      });
      if (upErr) return json({ error: "store_failed", detail: upErr.message }, 500);

      const r = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${RESEND_API_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from: FROM, to: email, subject: `رمز التحقق ${code} | Your QVM verification code`, html: otpEmailHtml(code) }),
      });
      if (!r.ok) return json({ error: "send_failed", detail: (await r.text()).slice(0, 300) }, 502);
      return json({ success: true, expires_in: OTP_TTL_MIN * 60 });
    }

    if (action === "verify") {
      const code = String(body?.code || "").trim();
      if (!/^\d{6}$/.test(code)) return json({ valid: false, reason: "format" });
      const { data: row } = await sb.from("email_otps").select("*").eq("email", email).maybeSingle();
      if (!row) return json({ valid: false, reason: "not_found" });
      if (row.verified) return json({ valid: true });
      if (new Date(row.expires_at).getTime() < Date.now()) return json({ valid: false, reason: "expired" });
      if (row.attempts >= MAX_ATTEMPTS) return json({ valid: false, reason: "too_many_attempts" });

      const ok = (await hashCode(code, email)) === row.code_hash;
      if (!ok) {
        await sb.from("email_otps").update({ attempts: row.attempts + 1 }).eq("email", email);
        return json({ valid: false, reason: "wrong", remaining: MAX_ATTEMPTS - row.attempts - 1 });
      }
      await sb.from("email_otps").update({ verified: true }).eq("email", email);
      return json({ valid: true });
    }

    return json({ error: "unknown_action" }, 400);
  } catch (e) {
    return json({ error: "server_error", detail: String((e as Error)?.message || e) }, 500);
  }
});
