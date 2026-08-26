import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

// Pricing modal "QSTOCK DATA" card: looks up other companies' live stock for a part number.
// dash.qvm.parts has no CORS headers and needs no auth — this just relays the call server-side
// so the browser isn't blocked, and keeps the third-party URL out of client code.
const QSTOCK_URL = "https://dash.qvm.parts/product/v1/qvm/pb/qvmProducts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type QstockLookupBody = {
  partNumber: string;
  max?: number;
  offset?: number;
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { partNumber, max, offset }: QstockLookupBody = await req.json();
    if (!partNumber || !String(partNumber).trim()) {
      return jsonResponse({ status: false, message: "partNumber is required", data: null }, 400);
    }

    const upstreamRes = await fetch(QSTOCK_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        partNumber: String(partNumber).trim(),
        productName: null,
        brandClass: null,
        brand: null,
        branchId: null,
        qvm: false,
        productCreated: null,
        liveStockLastUpdated: null,
        max: max ?? 10,
        offest: offset ?? 0,
      }),
    });

    if (!upstreamRes.ok) {
      return jsonResponse({ status: false, message: `QStock lookup failed (${upstreamRes.status})`, data: null }, 502);
    }

    const products = await upstreamRes.json();
    return jsonResponse({ status: true, message: "OK", data: products });
  } catch (err) {
    return jsonResponse({ status: false, message: String(err), data: null }, 500);
  }
});
