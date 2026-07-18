import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type DeliveredNoteItem = {
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

type DeliveredNote = {
  id: string;
  type: "DN" | "RN";
  status: string;
  orderNumber: string;
  orderDate: string;
  eventDate: string;
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
  items: DeliveredNoteItem[];
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return new Response(JSON.stringify({ error: "Missing Supabase env vars" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // Parse request
    let search = "";
    try {
      const body = await req.json();
      if (body && typeof body.search === "string") search = body.search.trim();
    } catch {}

    // Helper: basic filter builder
    const applySearchFilter = (rows: any[]) => {
      if (!search) return rows;
      const q = search.toLowerCase();
      return rows.filter((r) =>
        String(r.order_number || "").toLowerCase().includes(q) ||
        String(r.plate_number || "").toLowerCase().includes(q) ||
        String(r.vin || "").toLowerCase().includes(q)
      );
    };

    // Fetch rows via public RPC (schema-safe)
    const { data: rowsData, error: rowsErr } = await supabase
      .rpc("get_delivered_note_rows", { p_search: search, p_limit: 500 });
    if (rowsErr) throw rowsErr;

    const dnRows = (rowsData && (rowsData as any).dn) ? (rowsData as any).dn as any[] : [];
    const rnRows = (rowsData && (rowsData as any).rn) ? (rowsData as any).rn as any[] : [];

    const isIssuedStatus = (s: any) => typeof s === 'string' && s.toLowerCase().includes('issued');
    const dnActionable = (dnRows ?? []).filter((r: any) => !((r.invoice_number && String(r.invoice_number).length > 0) || isIssuedStatus(r.status)));
    const rnActionable = (rnRows ?? []).filter((r: any) => !((r.creditnote_number && String(r.creditnote_number).length > 0) || isIssuedStatus(r.status)));

    const filteredDnRows = applySearchFilter(dnActionable);
    const filteredRnRows = applySearchFilter(rnActionable);

    // Group DN by order_number and delivery_date
    const dnGrouped = new Map<string, any[]>();
    for (const row of filteredDnRows) {
      const key = `${row.order_number}::${row.delivery_date ?? row.created_at ?? ""}`;
      const arr = dnGrouped.get(key) ?? [];
      arr.push(row);
      dnGrouped.set(key, arr);
    }

    // Group RN by order_number and return_date
    const rnGrouped = new Map<string, any[]>();
    for (const row of filteredRnRows) {
      const key = `${row.order_number}::${row.return_date ?? row.created_at ?? ""}`;
      const arr = rnGrouped.get(key) ?? [];
      arr.push(row);
      rnGrouped.set(key, arr);
    }

    const notes: DeliveredNote[] = [];

    // Build DN notes
    for (const [key, rows] of dnGrouped.entries()) {
      const first = rows[0] ?? {};
      const orderNumber = String(first.order_number || "");

      let totalBeforeVat = 0;
      let totalWithVat = 0;
      let vatAmount = 0;

      const items: DeliveredNoteItem[] = rows.map((r: any) => {
        const unitPrice = Number(r.price_before_vat ?? 0) || 0;
        const qty = Number(r.approved_quantity ?? 0) || 0;
        const discount = Number(r.discount_percent ?? 0) || 0;
        // Use stored values (already correctly discounted). Fall back to calculation only if missing.
        const lineAfterDiscount = Number(r.total_price_before_vat ?? 0) || Math.round(unitPrice * qty * (1 - discount / 100) * 100) / 100;
        const rawTotalIncl = Number((r.total_price_including_vat ?? "").toString().replace(/[^0-9.\-]/g, "")) || 0;
        const totalIncl = rawTotalIncl > 0 ? rawTotalIncl : Math.round(lineAfterDiscount * 1.15 * 100) / 100;
        const vat = Math.round((totalIncl - lineAfterDiscount) * 100) / 100;
        totalBeforeVat += lineAfterDiscount;
        totalWithVat += totalIncl;
        vatAmount += vat;
        return {
          id: `ni-${String(r.confirmed_item_id ?? "0")}`,
          partNumber: String(r.final_part_number ?? ""),
          description: String(r.part_description ?? ""),
          brandClass: r.brand_class ? String(r.brand_class) : undefined,
          quantity: qty,
          priceBeforeVat: lineAfterDiscount,
          vatAmount: vat,
          totalWithVat: totalIncl,
        };
      });

      // Infer status
      const hasSignature = rows.some((r: any) => (r.signature && String(r.signature).length > 0) || (r.receipt_signature_email && String(r.receipt_signature_email).length > 0));
      const invoiceNumber = rows.find((r: any) => r.invoice_number)?.invoice_number ?? null;
      const status = hasSignature ? (invoiceNumber ? 'Invoice Issued' : 'Pending Invoice') : 'DN Sign Pending';

      // Exclude issued DN from Delivered Orders page (they belong to Archive)
      if (invoiceNumber && String(invoiceNumber).length > 0) {
        continue;
      }

      notes.push({
        id: `dn-${orderNumber}`,
        type: "DN",
        status,
        orderNumber,
        orderDate: String(first.order_date ?? ""),
        eventDate: String(first.delivery_date ?? first.created_at ?? ""),
        plateNumber: String(first.plate_number ?? ""),
        vin: String(first.vin ?? ""),
        brand: String(first.main_brand ?? ""),
        model: String(first.model ?? ""),
        client: String(first.client_name ?? ""),
        branch: String(first.branch ?? ""),
        totalBeforeVat,
        vatAmount,
        totalWithVat,
        shippingFees: Number(first.shipping_price ?? 0) || 0,
        signedBy: rows.find((r: any) => r.receipt_signature_email)?.receipt_signature_email ?? null,
        signedAt: null,
        invoiceNumber,
        items,
      });
    }

    // Build RN notes
    for (const [key, rows] of rnGrouped.entries()) {
      const first = rows[0] ?? {};
      const orderNumber = String(first.order_number || "");

      let totalBeforeVat = 0;
      let totalWithVat = 0;
      let vatAmount = 0;

      const items: DeliveredNoteItem[] = rows.map((r: any) => {
        const unitPrice = Number(r.price_before_vat ?? 0) || 0;
        const qty = Number(r.return_quantity ?? 0) || 0;
        const discount = Number(r.discount_percent ?? 0) || 0;
        // Use stored values (already correctly discounted). Fall back to calculation only if missing.
        const lineAfterDiscount = Number(r.total_price_before_vat ?? 0) || Math.round(unitPrice * qty * (1 - discount / 100) * 100) / 100;
        const rawTotalIncl = Number((r.total_price_including_vat ?? "").toString().replace(/[^0-9.\-]/g, "")) || 0;
        const totalIncl = rawTotalIncl > 0 ? rawTotalIncl : Math.round(lineAfterDiscount * 1.15 * 100) / 100;
        const vat = Math.round((totalIncl - lineAfterDiscount) * 100) / 100;
        totalBeforeVat += lineAfterDiscount;
        totalWithVat += totalIncl;
        vatAmount += vat;
        return {
          id: `ni-${String(r.confirmed_item_id ?? "0")}`,
          partNumber: String(r.final_part_number ?? ""),
          description: String(r.part_description ?? ""),
          brandClass: r.brand_class ? String(r.brand_class) : undefined,
          quantity: qty,
          priceBeforeVat: lineAfterDiscount,
          vatAmount: vat,
          totalWithVat: totalIncl,
        };
      });

      const hasSignature = rows.some((r: any) => (r.signature && String(r.signature).length > 0) || (r.receipt_signature_email && String(r.receipt_signature_email).length > 0));
      const creditnoteNumber = rows.find((r: any) => r.creditnote_number)?.creditnote_number ?? null;
      const status = hasSignature ? (creditnoteNumber ? 'Credit Note Issued' : 'Pending Credit Note') : 'RN Sign Pending';

      // Exclude issued RN from Delivered Orders page (they belong to Archive)
      if (creditnoteNumber && String(creditnoteNumber).length > 0) {
        continue;
      }

      notes.push({
        id: `rn-${orderNumber}`,
        type: "RN",
        status,
        orderNumber,
        orderDate: String(first.order_date ?? ""),
        eventDate: String(first.return_date ?? first.created_at ?? ""),
        plateNumber: String(first.plate_number ?? ""),
        vin: String(first.vin ?? ""),
        brand: String(first.main_brand ?? ""),
        model: String(first.model ?? ""),
        client: String(first.client_name ?? ""),
        branch: String(first.branch ?? ""),
        totalBeforeVat,
        vatAmount,
        totalWithVat,
        shippingFees: Number(first.shipping_price ?? 0) || 0,
        signedBy: rows.find((r: any) => r.receipt_signature_email)?.receipt_signature_email ?? null,
        signedAt: null,
        invoiceNumber: creditnoteNumber,
        items,
      });
    }

    // Fetch Out for Delivery orders that have no delivery note yet
    const { data: oofdRows, error: oofdErr } = await supabase
      .rpc('get_orders_with_item_status', { p_status_id: 22, p_user_id: null, p_limit: 500, p_offset: 0 });
    if (oofdErr) console.error('oofd fetch error:', oofdErr);
    const oofdData = (oofdRows && (oofdRows as any).data) ? (oofdRows as any).data as any[] : [];

    const oofdOrdersMap = new Map<string, any[]>();
    for (const order of oofdData) {
      const orderNumber = String(order.order_number || "");
      if (!orderNumber) continue;
      const hasDeliveryNote = dnRows.some((r: any) => String(r.order_number || "") === orderNumber);
      if (hasDeliveryNote) continue;
      const arr = oofdOrdersMap.get(orderNumber) ?? [];
      arr.push(order);
      oofdOrdersMap.set(orderNumber, arr);
    }

    for (const [orderNumber, orders] of oofdOrdersMap.entries()) {
      const order = orders[0] ?? {};

      let totalBeforeVat = 0;
      let totalWithVat = 0;
      let vatAmount = 0;

      const items: DeliveredNoteItem[] = (order.items || []).map((it: any) => {
        const unitPrice = Number(it.price_before_vat ?? 0) || 0;
        const qty = Number(it.approved_qty ?? it.quantity ?? 0) || 0;
        const discount = Number(it.discount_percent ?? 0) || 0;
        const vatRate = Number(it.vat ?? 15) || 15;
        const lineAfterDiscount = Math.round(unitPrice * qty * (1 - discount / 100) * 100) / 100;
        const lineIncl = Math.round(lineAfterDiscount * (1 + vatRate / 100) * 100) / 100;
        const lineVat = Math.round((lineIncl - lineAfterDiscount) * 100) / 100;
        totalBeforeVat += lineAfterDiscount;
        totalWithVat += lineIncl;
        vatAmount += lineVat;
        return {
          id: String(it.quotation_item_id ?? '0'),
          partNumber: String(it.part_number || ''),
          description: String(it.part_description || ''),
          brand: '',
          brandClass: String(it.brand_class ?? ''),
          quantity: qty,
          priceBeforeVat: lineAfterDiscount,
          vatAmount: lineVat,
          totalWithVat: lineIncl,
        };
      });

      if (search) {
        const q = search.toLowerCase();
        const matchOrder = orderNumber.toLowerCase().includes(q);
        const matchPlate = String(order.plate_number || '').toLowerCase().includes(q);
        const matchVin = String(order.vin || '').toLowerCase().includes(q);
        if (!matchOrder && !matchPlate && !matchVin) continue;
      }

      notes.push({
        id: `oofd-${orderNumber}`,
        type: "DN",
        status: "DN Sign Pending",
        orderNumber,
        orderDate: String(order.created_at || ''),
        eventDate: String(order.created_at || ''),
        plateNumber: String(order.plate_number || ''),
        vin: String(order.vin || ''),
        brand: String(order.brand || ''),
        model: String(order.model || ''),
        client: String(order.client_company || ''),
        branch: String(order.branch_name || ''),
        totalBeforeVat,
        vatAmount,
        totalWithVat,
        shippingFees: 0,
        items,
      });
    }

    // Final safety: exclude any issued statuses from Delivered Orders
    const actionable = notes.filter(n => !/issued/i.test(String(n.status)));
    // Sort combined notes by eventDate desc
    actionable.sort((a, b) => new Date(b.eventDate).getTime() - new Date(a.eventDate).getTime());

    return new Response(JSON.stringify({ status: true, message: "ok", data: actionable }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store, max-age=0" },
    });
  } catch (err: any) {
    console.error("list_delivered_notes error:", err);
    return new Response(JSON.stringify({ status: false, message: err?.message || "Unexpected error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store, max-age=0" },
    });
  }
});
