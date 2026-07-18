// deno-lint-ignore-file no-explicit-any
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.3";
import { PDFDocument, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import fontkit from "https://esm.sh/@pdf-lib/fontkit@1.1.1";

type RequestBody = {
  confirmed_order_id: number;
  user_id: string;
  delivery_id?: number | null;
  shipping_price?: number | null;
  shipping_cost?: number | null;
  payment_account?: number | null;
};

function buildCorsHeaders(req: Request): HeadersInit {
  const origin = req.headers.get('origin') || '*';
  return {
    "Access-Control-Allow-Origin": origin,
    "Vary": "Origin",
    "Access-Control-Allow-Credentials": "true",
    "Access-Control-Allow-Headers": "*, Authorization, authorization, apikey, content-type, Content-Type, x-client-info, X-Client-Info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
  } as HeadersInit;
}

async function loadArabicFont(): Promise<Uint8Array> {
  const url = Deno.env.get('ARABIC_FONT_URL')
    ?? 'https://cdn.jsdelivr.net/gh/aliftype/amiri-font@0.113/ttf/Amiri-Regular.ttf';
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`Failed to fetch font (${resp.status})`);
  const buf = await resp.arrayBuffer();
  return new Uint8Array(buf);
}

function money(n: any): string {
  const v = Number(n);
  return isFinite(v) ? v.toFixed(2) : '0.00';
}

function safeDateStr(iso?: string | null): string {
  if (!iso) return '';
  try {
    const d = new Date(iso);
    if (!isFinite(d.getTime())) return String(iso);
    try {
      return new Intl.DateTimeFormat('en-GB', {
        timeZone: 'Asia/Riyadh', year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
      }).format(d);
    } catch {
      return d.toISOString().slice(0, 19).replace('T', ' ');
    }
  } catch {
    return String(iso);
  }
}

Deno.serve(async (req: Request) => {
  const corsHeaders = buildCorsHeaders(req);
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    if (!authHeader.startsWith('Bearer ')) {
      return new Response(JSON.stringify({ error: 'Missing Authorization bearer token' }), { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
    if (!supabaseUrl || !serviceKey) {
      return new Response(JSON.stringify({ error: 'Server misconfiguration' }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    const supabaseAdmin = createClient(supabaseUrl, serviceKey);

    const body: RequestBody = await req.json();
    const confirmedOrderId = Number(body.confirmed_order_id);
    const userId = String(body.user_id || '');
    const deliveryId = body.delivery_id != null ? Number(body.delivery_id) : null;

    if (!confirmedOrderId || !userId) {
      return new Response(JSON.stringify({ error: 'confirmed_order_id and user_id are required' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    // Optional header updates before finalize
    if (body.shipping_price != null || body.shipping_cost != null || body.payment_account != null) {
      const { error: updErr } = await supabaseAdmin.rpc('update_delivery_note_header_inline', {
        p_user_id: userId,
        p_confirmed_order_id: confirmedOrderId,
        p_shipping_price: body.shipping_price ?? null,
        p_shipping_cost: body.shipping_cost ?? null,
        p_payment_account: body.payment_account ?? null,
      });
      if (updErr) {
        return new Response(JSON.stringify({ error: updErr.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
      }
    }

    // Get order_number via detail RPC (also validates internal access)
    const { data: detailRes, error: detailErr } = await supabaseAdmin.rpc('get_delivery_note_detail', {
      p_user_id: userId,
      p_confirmed_order_id: confirmedOrderId,
      p_delivery_id: deliveryId,
    });
    if (detailErr) {
      return new Response(JSON.stringify({ error: detailErr.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }
    const header = detailRes?.header || {};
    const orderNumber: string = header?.order_number || '';

    if (!orderNumber) {
      return new Response(JSON.stringify({ error: 'Order number not found for this delivery' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    // Fetch printable data
    const { data: dnRes, error: dnErr } = await supabaseAdmin.rpc('get_delivery_note', {
      p_order_number: orderNumber,
      p_delivery_id: deliveryId ?? null,
    });
    if (dnErr) {
      return new Response(JSON.stringify({ error: dnErr.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }
    if (!dnRes?.status || !dnRes?.data) {
      return new Response(JSON.stringify({ error: dnRes?.message || 'Failed to load delivery note' }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    const dn = dnRes.data as any;

    // Prepare PDF and embed a Unicode font that supports Arabic
    const pdfDoc = await PDFDocument.create();
    pdfDoc.registerFontkit(fontkit as any);
    const arabicFontBytes = await loadArabicFont();
    const arabicFont = await pdfDoc.embedFont(arabicFontBytes, { subset: false }); // full embed to avoid missing glyphs

    const pageMargin = { top: 40, right: 40, bottom: 60, left: 40 };
    const pageSize: [number, number] = [595.28, 841.89]; // A4 portrait

    const newPage = () => {
      const page = pdfDoc.addPage(pageSize);
      return page;
    };

    let page = newPage();
    const { width, height } = page.getSize();

    // Layout columns
    const col = {
      left: pageMargin.left,
      idx: pageMargin.left,
      descRight: width - pageMargin.right - 220, // wide description column RTL-aligned
      pn: width - pageMargin.right - 210,
      qty: width - pageMargin.right - 150,
      unit: width - pageMargin.right - 95,
      total: width - pageMargin.right - 30,
    };

    const drawRtl = (text: string, rightX: number, y: number, size = 12, color = rgb(0, 0, 0)) => {
      const s = String(text ?? '');
      const maxW = rightX - (col.idx + 16);
      let t = s;
      let w = arabicFont.widthOfTextAtSize(t, size);
      while (w > maxW && t.length > 1) {
        t = t.slice(0, -1);
        w = arabicFont.widthOfTextAtSize(t + '…', size);
        if (w <= maxW) { t = t + '…'; break; }
      }
      const x = rightX - arabicFont.widthOfTextAtSize(t, size);
      page.drawText(t, { x, y, size, font: arabicFont, color });
    };

    const draw = (text: string, x: number, y: number, size = 12, color = rgb(0, 0, 0)) => {
      page.drawText(String(text ?? ''), { x, y, size, font: arabicFont, color });
    };

    let y = height - pageMargin.top;

    // Header bar
    page.drawRectangle({ x: 0, y: y + 8, width, height: 28, color: rgb(0.94, 0.96, 1) });
    draw('Delivery Note / إشعار تسليم', pageMargin.left, y + 14, 16);

    y -= 40;
    // Draw labels and values separately to avoid bidi issues
    draw('Order:', pageMargin.left, y);
    draw(orderNumber, pageMargin.left + 120, y);
    y -= 18;

    draw('Order Date:', pageMargin.left, y);
    draw(safeDateStr(dn.header.order_date), pageMargin.left + 120, y);
    y -= 18;

    draw('Delivery Date:', pageMargin.left, y);
    draw(safeDateStr(dn.header.delivery_date), pageMargin.left + 120, y);
    y -= 18;

    draw('Buyer:', pageMargin.left, y);
    drawRtl(`${dn.header.buyer?.client_name ?? ''} - ${dn.header.buyer?.branch_name ?? ''}`, width - pageMargin.right, y);
    y -= 24;

    // Table header background
    page.drawRectangle({ x: pageMargin.left, y: y - 4, width: width - pageMargin.left - pageMargin.right, height: 22, color: rgb(0.95, 0.95, 0.95) });
    draw('#', col.idx, y + 3, 12);
    draw('الوصف', col.descRight - 40, y + 3, 12);
    draw('PN', col.pn, y + 3, 12);
    draw('Qty', col.qty, y + 3, 12);
    draw('Unit', col.unit, y + 3, 12);
    draw('Total', col.total, y + 3, 12);
    y -= 26;

    const items = Array.isArray(dn.items) ? dn.items : [];
    const rowHeight = 18;

    const ensureSpace = (needed = rowHeight) => {
      if (y - needed < pageMargin.bottom) {
        // Footer line before page break
        page.drawRectangle({ x: pageMargin.left, y: pageMargin.bottom - 6, width: width - pageMargin.left - pageMargin.right, height: 1, color: rgb(0.85, 0.85, 0.85) });
        // New page
        page = newPage();
        const dims = page.getSize();
        const w = dims.width;
        // recompute columns for new page
        (col as any).left = pageMargin.left;
        (col as any).idx = pageMargin.left;
        (col as any).descRight = w - pageMargin.right - 220;
        (col as any).pn = w - pageMargin.right - 210;
        (col as any).qty = w - pageMargin.right - 150;
        (col as any).unit = w - pageMargin.right - 95;
        (col as any).total = w - pageMargin.right - 30;
        y = dims.height - pageMargin.top;
        // Repeat table header
        page.drawRectangle({ x: pageMargin.left, y: y - 4, width: w - pageMargin.left - pageMargin.right, height: 22, color: rgb(0.95, 0.95, 0.95) });
        draw('#', (col as any).idx, y + 3, 12);
        draw('الوصف', (col as any).descRight - 40, y + 3, 12);
        draw('PN', (col as any).pn, y + 3, 12);
        draw('Qty', (col as any).qty, y + 3, 12);
        draw('Unit', (col as any).unit, y + 3, 12);
        draw('Total', (col as any).total, y + 3, 12);
        y -= 26;
      }
    };

    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      ensureSpace();
      draw(String(i + 1), col.idx, y);
      drawRtl(String(it.part_description ?? ''), col.descRight, y);
      draw(String(it.final_part_number ?? ''), col.pn, y);
      draw(String(it.delivered_qty ?? 0), col.qty, y);
      draw(money(it.unit_price_before_vat ?? it.unit_price_after_discount ?? 0), col.unit, y);
      draw(money(it.line_total_after_vat ?? 0), col.total, y);
      y -= rowHeight;
      // row separator
      page.drawRectangle({ x: pageMargin.left, y: y + 2, width: width - pageMargin.left - pageMargin.right, height: 0.6, color: rgb(0.92, 0.92, 0.92) });
    }

    // Totals section
    ensureSpace(90);
    y -= 8;
    page.drawRectangle({ x: pageMargin.left, y: y - 2, width: width - pageMargin.left - pageMargin.right, height: 1, color: rgb(0.8, 0.8, 0.8) });
    y -= 14;

    draw(`Subtotal: ${money(dn.totals?.subtotal_before_vat ?? 0)}`, col.unit - 60, y, 12); y -= 18;
    draw(`VAT: ${money(dn.totals?.vat_total ?? 0)}`, col.unit - 60, y, 12); y -= 18;
    draw(`Shipping: ${money(dn.totals?.shipping_fee ?? 0)}`, col.unit - 60, y, 12); y -= 20;

    // Grand total highlight
    page.drawRectangle({ x: col.unit - 64, y: y - 4, width: 250, height: 24, color: rgb(0.94, 0.96, 1) });
    draw(`Grand Total: ${money(dn.totals?.grand_total ?? 0)}`, col.unit - 60, y + 3, 14);

    const pdfBytes = await pdfDoc.save();

    // Ensure bucket exists then upload to Storage bucket
    const bucketName = Deno.env.get('DN_BUCKET') ?? 'delivery-notes';
    try {
      const { data: buckets } = await supabaseAdmin.storage.listBuckets();
      const exists = Array.isArray(buckets) && buckets.some((b: any) => b?.name === bucketName);
      if (!exists) {
        await supabaseAdmin.storage.createBucket(bucketName, {
          public: true,
          fileSizeLimit: '50MB',
          allowedMimeTypes: ['application/pdf'],
        });
      }
    } catch (_) { /* ignore */ }

    const fileName = `DN-${orderNumber.replace(/\s+/g, '-')}-${Date.now()}.pdf`;
    const { error: uploadErr } = await supabaseAdmin.storage
      .from(bucketName)
      .upload(fileName, new Blob([pdfBytes], { type: 'application/pdf' }), { upsert: true, contentType: 'application/pdf' });

    if (uploadErr) {
      return new Response(JSON.stringify({ error: uploadErr.message }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    // Prefer a public URL so the browser can open inline reliably
    const { data: pub } = await supabaseAdmin.storage.from(bucketName).getPublicUrl(fileName);
    const pdfUrl = pub?.publicUrl ?? null;

    // Finalize
    const { error: finErr } = await supabaseAdmin.rpc('finalize_delivery_note', {
      p_user_id: userId,
      p_confirmed_order_id: confirmedOrderId,
      p_delivery_id: deliveryId,
      p_pdf_url: pdfUrl,
    });
    if (finErr) {
      return new Response(JSON.stringify({ error: finErr.message }), { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
    }

    return new Response(JSON.stringify({ status: 'success', message: 'Delivery Note submitted', pdf_url: pdfUrl }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || 'Unexpected error' }), { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
  }
});