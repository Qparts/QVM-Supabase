// Self-registration: create a real account AFTER the email OTP is verified.
// Security: the role/type are FIXED server-side to a basic CLIENT (never internal/admin) — the
// client cannot choose a role. Creation is gated on email_otps.verified = true, so only someone
// who received (and entered) the emailed code can register that email.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const isEmail = (e: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);

const CLIENT_TYPE = 183; // "client" user_type
const CLIENT_ROLE = 171; // "Service Advisor" — lowest-privilege client role

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
      auth: { autoRefreshToken: false, persistSession: false },
      db: { schema: "qvm_new_apps" },
    });

    const body = await req.json().catch(() => ({}));
    const email = String(body?.email || "").trim().toLowerCase();
    const password = String(body?.password || "");
    const fullName = String(body?.full_name || "").trim();
    const phone = String(body?.phone || "").trim();
    const companyName = String(body?.company_name || "").trim();

    if (!isEmail(email)) return json({ error: "invalid_email" }, 400);
    if (password.length < 8) return json({ error: "weak_password" }, 400);

    // 1) The email must have a VERIFIED, unexpired OTP.
    const { data: otp } = await admin.from("email_otps").select("verified, expires_at").eq("email", email).maybeSingle();
    if (!otp?.verified) return json({ error: "email_not_verified" }, 403);
    if (new Date(otp.expires_at).getTime() < Date.now()) return json({ error: "verification_expired" }, 403);

    // 2) Not already registered (app-level).
    const { data: existing } = await admin.from("user_data").select("user_id").eq("email", email).maybeSingle();
    if (existing) return json({ error: "already_registered" }, 409);

    // 3) Create the auth user (email pre-confirmed — we already verified it via OTP).
    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
      user_metadata: { full_name: fullName, phone, company_name: companyName },
    });
    if (cErr || !created?.user) {
      const m = (cErr?.message || "").toLowerCase();
      if (m.includes("already") || m.includes("registered") || m.includes("exists")) return json({ error: "already_registered" }, 409);
      return json({ error: "create_failed", detail: cErr?.message }, 400);
    }
    const uid = created.user.id;

    // 4) Insert the profile row — role/type are FIXED here, never taken from the client.
    const { error: iErr } = await admin.from("user_data").insert({
      user_id: uid,
      user_name: fullName || email,
      email,
      user_type: CLIENT_TYPE,
      user_role: CLIENT_ROLE,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });
    if (iErr) {
      // Roll back the orphaned auth user so a retry can succeed cleanly.
      await admin.auth.admin.deleteUser(uid).catch(() => {});
      return json({ error: "profile_failed", detail: iErr.message }, 500);
    }

    // 5) Consume the OTP so it can't be reused.
    await admin.from("email_otps").delete().eq("email", email);

    return json({ success: true, user_id: uid });
  } catch (e) {
    return json({ error: "server_error", detail: String((e as Error)?.message || e) }, 500);
  }
});
