// Resolve a batch of IP addresses to an approximate country/city, server-side, so the user's
// session IPs are looked up in one controlled call (never scattered from the browser).
// Uses ip-api.com batch (free, no key). Private/local IPs are skipped.
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...cors, "Content-Type": "application/json" } });

const isPrivate = (ip: string): boolean =>
  /^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[0-1])\.|::1|fc00:|fe80:|0\.)/i.test(ip);

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  try {
    const body = await req.json().catch(() => ({}));
    const raw: string[] = Array.isArray(body?.ips) ? body.ips : [];
    const ips = Array.from(new Set(raw.filter((x) => typeof x === "string" && x.trim()))).slice(0, 100);
    const publicIps = ips.filter((ip) => !isPrivate(ip));
    if (!publicIps.length) return json({});

    const resp = await fetch(
      "http://ip-api.com/batch?fields=query,status,country,countryCode,city,regionName",
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(publicIps),
      },
    );
    if (!resp.ok) return json({});
    const arr = await resp.json().catch(() => []);
    const out: Record<string, { country?: string; countryCode?: string; city?: string; region?: string }> = {};
    if (Array.isArray(arr)) {
      for (const r of arr) {
        if (r?.status === "success" && r?.query) {
          out[r.query] = { country: r.country, countryCode: r.countryCode, city: r.city, region: r.regionName };
        }
      }
    }
    return json(out);
  } catch (e) {
    return json({ error: "server_error", detail: String((e as Error)?.message || e) }, 500);
  }
});
