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

// get_archive_note_rows applies LIMIT/OFFSET to flat delivery/return-item rows, but this
// endpoint groups those rows into one note per order_number+event_date before paginating -
// pulling a generous flat-row window (instead of the requested page_size) keeps a note's items
// from being split across pages by the RPC's own row-level limit.
const FLAT_ROW_FETCH_LIMIT = 5000;

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

    const token = authHeader.replace("Bearer ", "");
    const { data: authData, error: authErr } = await supabase.auth.getUser(token);
    if (authErr || !authData?.user) {
      return new Response("Unauthorized", { status: 401, headers: corsHeaders });
    }
    const userId = authData.user.id;

    // Input
    let search = "";
    let type: "all" | "dn" | "rn" = "all";
    let companyId: number | null = null;
    let branchId: number | null = null;
    let dateFrom: string | null = null;
    let dateTo: string | null = null;
    let page = 1;
    let pageSize = 50;
    try {
      const body = await req.json();
      if (body && typeof body.search === "string") search = body.search.trim();
      if (body && typeof body.type === "string") {
        const t = body.type.toLowerCase();
        if (t === "dn" || t === "rn" || t === "all") type = t;
      }
      if (body && typeof body.company_id === "number") companyId = body.company_id;
      if (body && typeof body.branch_id === "number") branchId = body.branch_id;
      if (body && typeof body.date_from === "string") dateFrom = body.date_from;
      if (body && typeof body.date_to === "string") dateTo = body.date_to;
      if (body && typeof body.page === "number" && body.page > 0) page = body.page;
      if (body && typeof body.page_size === "number" && body.page_size > 0) pageSize = body.page_size;
    } catch { /* empty body — use defaults */ }

    const { data: rowsJson, error: rowsErr } = await supabase.rpc('get_archive_note_rows', {
      p_user_id: userId,
      p_search: search,
      p_type: type,
      p_company_id: companyId,
      p_branch_id: branchId,
      p_date_from: dateFrom,
      p_date_to: dateTo,
      p_limit: FLAT_ROW_FETCH_LIMIT,
      p_offset: 0,
    });
    if (rowsErr) throw rowsErr;
    const dnRows = (rowsJson as any)?.dn ?? [];
    const rnRows = (rowsJson as any)?.rn ?? [];

    // Archive only shows notes with an issued invoice/credit note - other statuses
    // (pending invoice, return request, etc.) belong to the Delivered Orders page.
    const dnFiltered = (dnRows ?? []).filter((r: any) => r.invoice_number && String(r.invoice_number).length > 0);
    const rnFiltered = (rnRows ?? []).filter((r: any) => r.creditnote_number && String(r.creditnote_number).length > 0);

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
        client: String(first.company_name ?? ""),
        branch: String(first.branch_name ?? ""),
        totalBeforeVat,
        vatAmount,
        totalWithVat,
        shippingFees: 0,
        signedBy: rows.find((r: any) => r.delivery_signature_email)?.delivery_signature_email ?? null,
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
        client: String(first.company_name ?? ""),
        branch: String(first.branch_name ?? ""),
        totalBeforeVat,
        vatAmount,
        totalWithVat,
        shippingFees: 0,
        signedBy: rows.find((r: any) => r.return_signature_email)?.return_signature_email ?? null,
        signedAt: null,
        invoiceNumber: creditnoteNumber,
        items,
      });
    }

    // Sort by eventDate desc, then paginate at the note (not raw item-row) level
    notes.sort((a, b) => new Date(b.eventDate).getTime() - new Date(a.eventDate).getTime());

    const total = notes.length;
    const start = (page - 1) * pageSize;
    const pagedNotes = notes.slice(start, start + pageSize);

    return new Response(JSON.stringify({ status: true, message: "ok", data: pagedNotes, total, page, page_size: pageSize }), {
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
