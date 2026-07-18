// supabase/functions/generate_quotation_pdf/index.ts
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { jsPDF } from "https://esm.sh/jspdf@2.5.1";
import autoTable from "https://esm.sh/jspdf-autotable@3.5.28";
// ✅ Insert your base64 files
import { amiriFontBase64 } from "./amiri-regular-base64.ts";
import { amiriBoldBase64 } from "./amiri-bold-base64.ts";
import { loraFontBase64 } from "./lora-regular-base64.ts";
import { loraBoldBase64 } from "./lora-bold-base64.ts";
import { qpartsLogoBase64 } from "./qparts-logo-base64.ts";
serve(async (req)=>{
  const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const { order_number, user_id } = await req.json();
  if (!order_number || !user_id) {
    return new Response(JSON.stringify({
      error: "Missing inputs"
    }), {
      status: 400
    });
  }
  // 🟢 Call your existing SQL function
  const { data: rows, error } = await supabase.rpc("fetch_rfqs_details", {
    p_order_number: order_number,
    p_user_id: user_id
  });
  if (error || !rows || rows.length === 0) {
    return new Response(JSON.stringify({
      error: "Failed to fetch order or no items found."
    }), {
      status: 400
    });
  }
  // 📝 Get general info from first row
  const { created_at, plate_number, client_name } = rows[0];
  // 🔸 Dynamic Buyer Name (Client + All Branches)
  const branches = [
    ...new Set(rows.map((r)=>r.branch))
  ].join(" - ");
  const buyerName = `${client_name} - ${branches}`;
  // 🔸 Dynamic SLA
  let sla;
  const allSameDay = rows.every((r)=>r.sla === "Same Day");
  if (allSameDay) {
    sla = "Same Day";
  } else {
    const days = rows.map((r)=>parseInt(r.sla, 10)).filter((n)=>!isNaN(n));
    sla = `${Math.max(...days)} Day(s)`;
  }
  // 🖨️ Generate PDF
  const doc = new jsPDF({
    orientation: "landscape"
  });
  doc.addFileToVFS("Amiri-Regular.ttf", amiriFontBase64);
  doc.addFont("Amiri-Regular.ttf", "Amiri", "normal");
  doc.addFileToVFS("Lora-Regular.ttf", loraFontBase64);
  doc.addFont("Lora-Regular.ttf", "Lora", "normal");
  doc.addFileToVFS("Amiri-Bold.ttf", amiriBoldBase64);
  doc.addFont("Amiri-Bold.ttf", "Amiri", "bold");
  doc.addFileToVFS("Lora-Bold.ttf", loraBoldBase64);
  doc.addFont("Lora-Bold.ttf", "Lora", "bold");
  // 🖼️ Logo
  doc.addImage(qpartsLogoBase64, "PNG", 200, 20, 60, 30);
  // 🔸 Title
  doc.setFont("Lora", "bold");
  doc.setFontSize(31);
  doc.text("Quotation", 135, 35, {
    align: "center"
  });
  // 🔹 Order Info
  const startY = 55;
  doc.setFont("Lora", "bold");
  doc.setFontSize(15);
  doc.text("Order No.:", 35, startY + 12);
  doc.setFont("Lora", "normal");
  doc.setFontSize(12);
  doc.text(order_number, 70, startY + 12);
  doc.setFont("Lora", "bold");
  doc.setFontSize(15);
  doc.text("Order Date:", 35, startY + 24);
  doc.setFont("Lora", "normal");
  doc.setFontSize(12);
  doc.text(new Date(created_at).toLocaleDateString("en-GB"), 70, startY + 24);
  doc.setFont("Lora", "bold");
  doc.setFontSize(15);
  doc.text("Buyer Name:", 35, startY + 36);
  doc.setFont("Lora", "normal");
  doc.setFontSize(12);
  doc.text(buyerName, 70, startY + 36);
  doc.setFont("Lora", "bold");
  doc.setFontSize(15);
  doc.text("Plate No.:", 170, startY + 12);
  doc.setFont("Lora", "normal");
  doc.setFontSize(12);
  doc.text(plate_number, 200, startY + 12);
  doc.setFont("Lora", "bold");
  doc.setFontSize(15);
  doc.text("SLA:", 170, startY + 24);
  doc.setFont("Lora", "normal");
  doc.setFontSize(12);
  doc.text(sla, 200, startY + 24);
  doc.setFont("Lora", "bold");
  doc.setFontSize(15);
  doc.text("Seller Name:", 170, startY + 36);
  doc.setFont("Amiri", "normal");
  doc.text("شركة تطبيق قطع للتجارة", 245, startY + 36, {
    align: "right"
  });
  const body = rows.map((r)=>[
      r.final_part_number || "",
      r.part_description || "",
      r.main_brand || "",
      r.brand_class || "",
      r.quantity,
      (r.cost_before_vat || 0).toFixed(1),
      (r.total_cost_before_vat || 0).toFixed(1),
      ((r.total_cost_before_vat || 0) * 0.15).toFixed(2),
      ((r.total_cost_before_vat || 0) * 1.15).toFixed(2)
    ]);
  autoTable(doc, {
    startY: 100,
    head: [
      [
        "Part No.",
        "Part Description",
        "Brand",
        "Class",
        "Qty",
        "Cost\nBefore VAT",
        "Total\nBefore VAT",
        "VAT",
        "Total\nWith VAT"
      ]
    ],
    body,
    styles: {
      fontSize: 12,
      cellPadding: 2,
      textColor: 0,
      halign: "center",
      valign: 'middle',
      font: 'Amiri-Regular',
      lineColor: [
        0,
        0,
        0
      ],
      lineWidth: 0.1 // 🔸 Border thickness
    },
    headStyles: {
      fillColor: [
        243,
        243,
        243
      ],
      textColor: 0,
      fontStyle: 'bold',
      font: 'Lora',
      halign: "center",
      valign: 'middle',
      lineColor: [
        0,
        0,
        0
      ],
      lineWidth: 0.1 // 🔸 Border thickness
    },
    columnStyles: {
      0: {
        cellWidth: 'auto'
      },
      1: {
        cellWidth: 'auto'
      },
      2: {
        cellWidth: 'auto'
      },
      3: {
        cellWidth: 'auto'
      },
      4: {
        cellWidth: 'auto'
      },
      5: {
        cellWidth: 20
      },
      6: {
        cellWidth: 30
      },
      7: {
        cellWidth: 20
      },
      8: {
        cellWidth: 28
      }
    },
    theme: 'grid'
  });
  // 📊 Totals
  const totalBefore = rows.reduce((sum, r)=>sum + Number(r.total_cost_before_vat || 0), 0);
  const vat = totalBefore * 0.15;
  const totalAfter = totalBefore * 1.15;
  autoTable(doc, {
    startY: doc.lastAutoTable.finalY + 5,
    body: [
      [
        "Total",
        totalBefore.toFixed(1),
        vat.toFixed(1),
        totalAfter.toFixed(1)
      ]
    ],
    theme: 'grid',
    styles: {
      fontSize: 12,
      fontStyle: 'bold',
      halign: 'center',
      valign: 'middle',
      textColor: 0,
      font: 'Lora',
      lineColor: [
        0,
        0,
        0
      ],
      lineWidth: 0.1,
      fillColor: [
        243,
        243,
        243
      ]
    },
    columnStyles: {
      0: {
        cellWidth: 191
      },
      1: {
        cellWidth: 30
      },
      2: {
        cellWidth: 20
      },
      3: {
        cellWidth: 28
      }
    },
    head: [],
    showHead: 'never' // 👈 make sure headers are hidden
  });
  // ⬆️ Upload to Supabase Storage
  const pdfBlob = doc.output("blob");
  const timestamp = Date.now();
  const fileName = `quotations/Quotation-${order_number}-${timestamp}.pdf`;
  const { error: uploadError } = await supabase.storage.from("quotations-pdfs").upload(fileName, pdfBlob, {
    contentType: "application/pdf",
    upsert: true
  });
  if (uploadError) {
    return new Response(JSON.stringify({
      error: "Failed to upload PDF"
    }), {
      status: 500
    });
  }
  const { data: { publicUrl } } = supabase.storage.from("quotations-pdfs").getPublicUrl(fileName);
  return new Response(JSON.stringify({
    url: publicUrl
  }), {
    status: 200,
    headers: {
      "Content-Type": "application/json"
    }
  });
});
