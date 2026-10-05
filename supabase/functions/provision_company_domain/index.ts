// provision_company_domain — puts a company's host on the Netlify site, or takes it off.
//
// The Qparts Admin gives a company a subdomain in the database (admin_set_company_domain); this
// function makes Netlify serve it: it appends the host to the site's domain aliases, or removes
// it, and records the outcome on the row. Netlify DNS creates the record and the certificate on
// its own once the alias exists, so there is nothing else to do.
//
// Who may call: a signed-in Qparts Admin (checked through the database as that user). What it
// touches: the one row it is asked about, read and written through service-role-only functions.
// Secrets: NETLIFY_AUTH_TOKEN (a Netlify personal access token), NETLIFY_SITE_ID (the site that
// serves the base domain), and optionally NETLIFY_DNS_ZONE_ID (the Netlify DNS zone of the base
// domain). The zone carries a wildcard A record to Netlify's load balancer, because some networks
// cannot reach Netlify's regional edge addresses; when an alias is added Netlify also writes a
// NETLIFY record for that one host, which would send it to the edge again, so that record is
// removed and the wildcard answers for it.
//
// Body: { domain_id: number, action?: "add" | "remove" }. The action defaults from the row's state:
// a disabled row is removed, anything else is added.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function netlify(path: string, token: string, init: RequestInit = {}) {
  const res = await fetch(`https://api.netlify.com/api/v1${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init.headers || {}) },
  });
  const text = await res.text();
  let data: unknown = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) throw new Error(`Netlify ${res.status}: ${typeof data === "string" ? data : JSON.stringify(data)}`);
  return data as Record<string, unknown>;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ status: "fail", message: "POST only" }, 405);

  const token = Deno.env.get("NETLIFY_AUTH_TOKEN");
  const siteId = Deno.env.get("NETLIFY_SITE_ID");
  if (!token || !siteId) return json({ status: "fail", message: "Domain provisioning is not configured (NETLIFY_AUTH_TOKEN, NETLIFY_SITE_ID)" }, 503);

  // Who is asking: the user's own JWT, and the database's answer on whether they are the Qparts Admin.
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ status: "fail", message: "Not authorized" }, 401);
  const asUser = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const { data: isAdmin, error: adminErr } = await asUser.schema("qvm_new_apps").rpc("is_qparts_admin");
  if (adminErr || isAdmin !== true) return json({ status: "fail", message: "Only the Qparts Admin provisions company domains" }, 403);

  let body: { domain_id?: number; action?: string } = {};
  try { body = await req.json(); } catch { return json({ status: "fail", message: "Malformed body" }, 400); }
  const domainId = Number(body.domain_id);
  if (!domainId) return json({ status: "fail", message: "domain_id is required" }, 400);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  const { data: row, error: rowErr } = await admin.rpc("company_domain_for_provisioning", { p_domain_id: domainId });
  if (rowErr || !row) return json({ status: "fail", message: rowErr?.message || "Unknown domain" }, 404);
  const host = String((row as Record<string, unknown>).host || "");
  const action = body.action === "remove" || body.action === "add" ? body.action : ((row as Record<string, unknown>).status === "disabled" ? "remove" : "add");

  try {
    const site = await netlify(`/sites/${siteId}`, token);
    const aliases: string[] = Array.isArray(site.domain_aliases) ? (site.domain_aliases as string[]) : [];
    const primary = String(site.custom_domain || "");
    const has = aliases.includes(host) || primary === host;
    let next = aliases;
    if (action === "add" && !has) next = [...aliases, host];
    if (action === "remove" && aliases.includes(host)) next = aliases.filter((a) => a !== host);
    if (next !== aliases) {
      await netlify(`/sites/${siteId}`, token, { method: "PATCH", body: JSON.stringify({ domain_aliases: next }) });
    }
    // Keep the host on the wildcard: drop the edge-pointing record Netlify writes for a new alias.
    const zoneId = Deno.env.get("NETLIFY_DNS_ZONE_ID");
    if (zoneId && action === "add") {
      try {
        const records = await netlify(`/dns_zones/${zoneId}/dns_records`, token) as unknown as Array<Record<string, unknown>>;
        for (const r of records) {
          if (r.type === "NETLIFY" && String(r.hostname).toLowerCase() === host.toLowerCase()) {
            await netlify(`/dns_zones/${zoneId}/dns_records/${r.id}`, token, { method: "DELETE" });
          }
        }
      } catch (e) {
        // The host still works through the edge where that is reachable; the record can be removed by hand.
        console.warn("could not tidy the DNS record for", host, String((e as Error)?.message || e));
      }
    }
    const status = action === "add" ? "active" : "disabled";
    const { data: marked, error: markErr } = await admin.rpc("mark_company_domain", { p_domain_id: domainId, p_status: status, p_error: null });
    if (markErr) return json({ status: "fail", message: markErr.message }, 500);
    return json({ status: "success", action, host, changed: next !== aliases, domain: marked });
  } catch (e) {
    const message = String((e as Error)?.message || e);
    // A refusal is recorded on the row so the panel can show it and offer a retry.
    if (action === "add") await admin.rpc("mark_company_domain", { p_domain_id: domainId, p_status: "failed", p_error: message });
    return json({ status: "fail", message }, 502);
  }
});
