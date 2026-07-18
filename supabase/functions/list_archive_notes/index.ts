import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Types align with frontend DeliveredNote/NoteItem

type NoteItem = {
  id: string;
  partNumber: string;
  description: string;
  brand?: string;
  brandClass?: string;
  quantity: number;
  priceBeforeVat?: number;
  vatAmount?: number;
  totalWithVat?: number;
};

type NoteType = "DN" | "RN";

type Note = {
  id: string;
  type: NoteType;
  status: string; // Invoice Issued | Credit Note Issued
  orderNumber: string;
  orderDate: string;
  eventDate: string; // delivery_date or return_date
  plateNumber: string;
  vin: string;
  brand: string;
  model: string;
  client: string;
  branch: string;
  totalBeforeVat: number;
  vatAmount: number;
  totalWithVat: number;
  shippingFees: number;
  signedBy?: string | null;
  signedAt?: string | null;
  invoiceNumber?: string | null;
  items: NoteItem[];
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function toNumber(val: any): number {
  const n = Number((val ?? "").toString().replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(n) ? n : 0;
}

function parseEventDate(row: any, kind: NoteType): string {
  if (kind === "DN") return String(row.delivery_date ?? row.created_at ?? "");
  return String(row.return_date ?? row.created_at ?? "");
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization") || req.headers.get("authorization");
    if (!authHeader) return new Response("Unauthorized", { status: 401, headers: corsHeaders });

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return new Response(JSON.stringify({ error: "Missing Supabase env vars" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // Input
    let search = "";
    let type: "all" | "dn" | "rn" = "all";
    let days = 30;
    try {
      const body = await req.json();
      if (body && typeof body.search === "string") search = body.search.trim();
      if (body && typeof body.type === "string") {
        const t = body.type.toLowerCase();
        if (t === "dn" || t === "rn" || t === "all") type = t;
      }
      if (body && typeof body.days === "number" && body.days > 0 && body.days <= 3650) days = body.days;
    } catch {}

    // Fetch rows via public RPC to satisfy PostgREST schema restrictions
    const { data: rowsJson, error: rowsErr } = await supabase.rpc('get_archive_note_rows', {
      p_search: search,
      p_type: type,
      p_days: days,
    });
    if (rowsErr) throw rowsErr;
    const dnRows = (rowsJson as any)?.dn ?? [];
    const rnRows = (rowsJson as any)?.rn ?? [];

    // Filters
    const since = new Date();
    since.setDate(since.getDate() - days);

    const applyCommonFilters = (rows: any[], kind: NoteType) => {
      const withDoc = rows.filter((r) =>
        kind === "DN" ? (r.invoice_number && String(r.invoice_number).length > 0) : (r.creditnote_number && String(r.creditnote_number).length > 0)
      );
      const afterDate = withDoc.filter((r) => {
        const d = new Date(parseEventDate(r, kind));
        return isFinite(d.getTime()) ? d >= since : true;
      });
      const q = search.toLowerCase();
      const byText = q
        ? afterDate.filter((r) =>
            String(r.order_number || "").toLowerCase().includes(q) ||
            String(r.plate_number || "").toLowerCase().includes(q) ||
            String(r.vin || "").toLowerCase().includes(q)
          )
        : afterDate;
      return byText;
    };

    const dnFiltered = type === "rn" ? [] : applyCommonFilters(dnRows ?? [], "DN");
    const rnFiltered = type === "dn" ? [] : applyCommonFilters(rnRows ?? [], "RN");

    // Grouping by order_number + event date
    const groupByKey = (rows: any[], kind: NoteType) => {
      const map = new Map<string, any[]>();
      for (const r of rows) {
        const key = `${r.order_number}::${parseEventDate(r, kind)}`;
        const arr = map.get(key) ?? [];
        arr.push(r);
        map.set(key, arr);
      }
      return map;
    };

    const dnGrouped = groupByKey(dnFiltered, "DN");
    const rnGrouped = groupByKey(rnFiltered, "RN");

    const notes: Note[] = [];

    for (const [key, rows] of dnGrouped.entries()) {
      const first = rows[0] ?? {};
      const orderNumber = String(first.order_number || "");
      let totalBeforeVat = 0, totalWithVat = 0, vatAmount = 0;
      const items: NoteItem[] = rows.map((r: any) => {
        const priceBefore = toNumber(r.price_before_vat);
        const totalIncl = toNumber(r.total_price_including_vat);
        const qty = toNumber(r.approved_quantity);
        const vat = Math.max(totalIncl - priceBefore, 0);
        totalBeforeVat += priceBefore;
        totalWithVat += totalIncl;
        vatAmount += vat;
        return {
          id: `ni-${String(r.confirmed_item_id ?? "0")}`,
          partNumber: String(r.final_part_number ?? ""),
          description: String(r.part_description ?? ""),
          brandClass: r.brand_class ? String(r.brand_class) : undefined,
          quantity: qty,
          priceBeforeVat: priceBefore,
          vatAmount: vat,
          totalWithVat: totalIncl,
        };
      });

      const invoiceNumber = rows.find((r: any) => r.invoice_number)?.invoice_number ?? null;
      notes.push({
        id: `dn-${orderNumber}`,
        type: "DN",
        status: "Invoice Issued",
        orderNumber,
        orderDate: String(first.order_date ?? ""),
        eventDate: parseEventDate(first, "DN"),
        plateNumber: String(first.plate_number ?? ""),
        vin: String(first.vin ?? ""),
        brand: String(first.main_brand ?? ""),
        model: String(first.model ?? ""),
        client: String(first.client_name ?? ""),
        branch: String(first.branch ?? ""),
        totalBeforeVat,
        vatAmount,
        totalWithVat,
        shippingFees: 0,
        signedBy: rows.find((r: any) => r.receipt_signature_email)?.receipt_signature_email ?? null,
        signedAt: null,
        invoiceNumber,
        items,
      });
    }

    for (const [key, rows] of rnGrouped.entries()) {
      const first = rows[0] ?? {};
      const orderNumber = String(first.order_number || "");
      let totalBeforeVat = 0, totalWithVat = 0, vatAmount = 0;
      const items: NoteItem[] = rows.map((r: any) => {
        const priceBefore = toNumber(r.price_before_vat);
        const totalIncl = toNumber(r.total_price_including_vat);
        const qty = toNumber(r.return_quantity);
        const vat = Math.max(totalIncl - priceBefore, 0);
        totalBeforeVat += priceBefore;
        totalWithVat += totalIncl;
        vatAmount += vat;
        return {
          id: `ni-${String(r.confirmed_item_id ?? "0")}`,
          partNumber: String(r.final_part_number ?? ""),
          description: String(r.part_description ?? ""),
          brandClass: r.brand_class ? String(r.brand_class) : undefined,
          quantity: qty,
          priceBeforeVat: priceBefore,
          vatAmount: vat,
          totalWithVat: totalIncl,
        };
      });

      const creditnoteNumber = rows.find((r: any) => r.creditnote_number)?.creditnote_number ?? null;
      notes.push({
        id: `rn-${orderNumber}`,
        type: "RN",
        status: "Credit Note Issued",
        orderNumber,
        orderDate: String(first.order_date ?? ""),
        eventDate: parseEventDate(first, "RN"),
        plateNumber: String(first.plate_number ?? ""),
        vin: String(first.vin ?? ""),
        brand: String(first.main_brand ?? ""),
        model: String(first.model ?? ""),
        client: String(first.client_name ?? ""),
        branch: String(first.branch ?? ""),
        totalBeforeVat,
        vatAmount,
        totalWithVat,
        shippingFees: 0,
        signedBy: rows.find((r: any) => r.receipt_signature_email)?.receipt_signature_email ?? null,
        signedAt: null,
        invoiceNumber: creditnoteNumber,
        items,
      });
    }

    // Sort by eventDate desc
    notes.sort((a, b) => new Date(b.eventDate).getTime() - new Date(a.eventDate).getTime());

    return new Response(JSON.stringify({ status: true, message: "ok", data: notes }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err: any) {
    console.error("list_archive_notes error:", err);
    return new Response(JSON.stringify({ status: false, message: err?.message || "Unexpected error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
