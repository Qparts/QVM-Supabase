import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type SubmitPayload = {
  user_id: string;
  confirmed_order_id: number;
  return_id?: number | null;
  shipping_price?: number | null;
  shipping_cost?: number | null;
  payment_account?: number | null;
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return new Response(JSON.stringify({ status: "error", message: "Missing Supabase env vars" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(supabaseUrl, serviceRoleKey);

    let body: SubmitPayload;
    try {
      body = await req.json();
    } catch {
      return new Response(JSON.stringify({ status: "error", message: "Invalid JSON body" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const {
      user_id,
      confirmed_order_id,
      return_id = null,
      shipping_price = null,
      shipping_cost = null,
      payment_account = null,
    } = body || {} as SubmitPayload;

    if (!user_id || !confirmed_order_id) {
      return new Response(JSON.stringify({ status: "error", message: "user_id and confirmed_order_id are required" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // 1) Finalize RN: persist header edits, update statuses, log
    {
      const { data, error } = await supabase.rpc('finalize_return_note', {
        p_user_id: user_id,
        p_confirmed_order_id: confirmed_order_id,
        p_return_id: return_id,
        p_shipping_price: shipping_price,
        p_shipping_cost: shipping_cost,
        p_payment_account: payment_account,
      });
      if (error) throw error;
      // Ensure we have a concrete return_id for subsequent ops
      if (data && data.return_id) {
        // @ts-ignore
        body.return_id = data.return_id;
      }
    }

    // 2) Resolve order number for naming
    let orderNumber = '';
    {
      const { data, error } = await supabase.rpc('get_order_number_by_confirmed_order', { p_confirmed_order_id: confirmed_order_id });
      if (error) throw error;
      orderNumber = String(data || '');
    }

    // 3) Fetch RN data for PDF
    let rn: any = null;
    {
      const { data, error } = await supabase.rpc('get_return_note', {
        p_order_number: orderNumber,
        p_return_id: body.return_id ?? null,
        p_confirmed_order_id: confirmed_order_id,
      });
      if (error) throw error;
      if (!data?.status || !data?.data) {
        throw new Error(data?.message || 'Failed to load return note for PDF');
      }
      rn = data.data;
    }

    // 4) Build a simple PDF
    const pdfDoc = await PDFDocument.create();
    let page = pdfDoc.addPage([595.28, 841.89]); // A4 portrait in points
    const { width } = page.getSize();
    const font = await pdfDoc.embedFont(StandardFonts.Helvetica);

    let y = 800;

    const drawText = (text: string, x = 40, size = 12, color = rgb(0, 0, 0)) => {
      page.drawText(text, { x, y, size, font, color });
      y -= size + 6;
    };

    // Header
    drawText('Return Note', 40, 20, rgb(0.1, 0.1, 0.4));
    drawText(`Order Number: ${rn.header.order_number}`);
    drawText(`Order Date: ${rn.header.order_date ?? ''}`);
    drawText(`Return Date: ${rn.header.return_date ?? ''}`);
    drawText(`Buyer: ${rn.header.buyer.client_name} — ${rn.header.buyer.branch_name}`);
    drawText(`Seller: ${rn.header.seller_name}`);
    drawText(`Plate Number: ${rn.header.plate_number ?? '-'}`);

    y -= 8;
    page.drawLine({ start: { x: 40, y }, end: { x: width - 40, y }, thickness: 1, color: rgb(0.8, 0.8, 0.8) });
    y -= 16;

    // Items header
    drawText('Items:', 40, 14, rgb(0.2, 0.2, 0.2));
    const headSize = 10;
    page.drawText('Description', { x: 40, y, size: headSize, font });
    page.drawText('Final PN', { x: 240, y, size: headSize, font });
    page.drawText('Qty', { x: 340, y, size: headSize, font });
    page.drawText('VAT', { x: 380, y, size: headSize, font });
    page.drawText('Total (VAT)', { x: 430, y, size: headSize, font });
    y -= 14;

    for (const it of rn.items as any[]) {
      if (y < 120) {
        // new page
        y = 800;
        page = pdfDoc.addPage([595.28, 841.89]);
        page.drawText('Items (cont.)', { x: 40, y, size: 12, font });
        y -= 16;
      }
      const desc = String(it.part_description || '');
      const pn = String(it.final_part_number || '');
      const qty = String(it.returned_qty || 0);
      const vat = String((it.line_vat_amount ?? 0).toFixed ? it.line_vat_amount.toFixed(2) : it.line_vat_amount);
      const total = String((it.line_total_after_vat ?? 0).toFixed ? it.line_total_after_vat.toFixed(2) : it.line_total_after_vat);
      page.drawText(desc.substring(0, 26), { x: 40, y, size: 10, font });
      page.drawText(pn.substring(0, 14), { x: 240, y, size: 10, font });
      page.drawText(qty, { x: 340, y, size: 10, font });
      page.drawText(vat, { x: 380, y, size: 10, font });
      page.drawText(total, { x: 430, y, size: 10, font });
      y -= 14;
    }

    y -= 8;
    page.drawLine({ start: { x: 40, y }, end: { x: width - 40, y }, thickness: 1, color: rgb(0.8, 0.8, 0.8) });
    y -= 16;

    // Totals
    drawText(`Subtotal (Before VAT): ${Number(rn.totals.subtotal_before_vat ?? 0).toFixed(2)}`);
    drawText(`VAT Total: ${Number(rn.totals.vat_total ?? 0).toFixed(2)}`);
    drawText(`Shipping Fee: ${Number(rn.totals.shipping_fee ?? 0).toFixed(2)}`);
    drawText(`Grand Total: ${Number(rn.totals.grand_total ?? 0).toFixed(2)}`, 40, 12, rgb(0.1, 0.1, 0.4));

    const pdfBytes = await pdfDoc.save();

    // 5) Upload PDF to Storage
    const bucket = 'return-notes';
    // Try to create bucket (idempotent-ish)
    try {
      // @ts-ignore - admin API available with service role
      await (supabase.storage as any).createBucket(bucket, { public: false });
    } catch { /* ignore if exists */ }

    const ts = new Date().toISOString().replace(/[:.]/g, '-');
    const filePath = `RN-${orderNumber}-${ts}.pdf`;

    const { error: uploadErr } = await supabase.storage.from(bucket).upload(filePath, new Blob([pdfBytes], { type: 'application/pdf' }), {
      upsert: true,
      contentType: 'application/pdf',
    });
    if (uploadErr) throw uploadErr;

    const { data: signed, error: signedErr } = await supabase.storage.from(bucket).createSignedUrl(filePath, 60 * 60 * 24 * 7);
    if (signedErr) throw signedErr;

    return new Response(JSON.stringify({ status: 'success', message: 'Return note submitted', pdf_url: signed?.signedUrl ?? null, file_path: `${bucket}/${filePath}` }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store, max-age=0" },
    });
  } catch (err: any) {
    console.error('submit_return_note error:', err);
    return new Response(JSON.stringify({ status: 'error', message: err?.message || 'Unexpected error' }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store, max-age=0" },
    });
  }
});
