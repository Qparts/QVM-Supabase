import { serve } from "https://deno.land/std/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js";

/* ---------- Helpers ---------- */

function getAnswerByName(
  answers: Record<string, any>,
  fieldName: string
) {
  return Object.values(answers).find(
    (a: any) => a.name === fieldName
  )?.answer ?? null;
}

function findFieldByTypeAndName(
  answers: Record<string, any>,
  type: string,
  name: string
) {
  return Object.values(answers).find(
    (a: any) => a.type === type && a.name === name
  );
}

// Slot logic
function getSlotFromDate(dateStr: string): number | null {
  const h = new Date(dateStr).getHours();
  if (h >= 21 || h < 13) return 1;
  if (h >= 13 && h < 17) return 2;
  if (h >= 17 && h < 21) return 3;
  return null;
}

function getWeekdayColumn(dateStr: string): string {
  return new Date(dateStr)
    .toLocaleDateString("en-US", { weekday: "long" })
    .toLowerCase();
}

/* ---------- Function ---------- */

serve(async (req: Request): Promise<Response> => {
  console.log("🔥 WEBHOOK HIT", new Date().toISOString());
  console.log("📨 Request headers:", Object.fromEntries(req.headers.entries()));
  try {
    /* ---------- Parse submission ---------- */

    const formData = await req.formData();
    console.log("📦 FormData keys received:", Array.from(formData.keys()));

    for (const [key, value] of formData.entries()) {
    console.log(`📄 formData[${key}]:`, value);
    }

    const submissionId =
      formData.get("submissionID")?.toString() ??
      formData.get("id")?.toString() ??
      null;

    if (!submissionId) {
      console.log("❌ No submission ID");
      return new Response(JSON.stringify({ ok: false }), { status: 400 });
    }

    /* ---------- Secrets ---------- */

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const JF_KEY = Deno.env.get("CARAAGY_API_KEY")!;

    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

    /* ---------- Fetch Jotform submission ---------- */

    const apiResp = await fetch(
      `https://api.jotform.com/submission/${submissionId}?apiKey=${JF_KEY}`
    );
    const apiData = await apiResp.json();
    console.log("🕒 Raw Jotform created_at:", apiData?.content?.created_at);
    console.log("🕒 Raw Jotform created_at (Date object):", apiData?.content?.created_at ? new Date(apiData.content.created_at).toString(): null);
    console.log("🕒 Raw Jotform created_at (ISO):", apiData?.content?.created_at? new Date(apiData.content.created_at).toISOString(): null);

   if (!apiData?.content?.answers) {
    return new Response(JSON.stringify({ ok: false }), { status: 400 });
    }
    if (!apiData?.content?.answers) {
      return new Response(JSON.stringify({ ok: false }), { status: 400 });
    }

    const answers = apiData.content.answers;

    /* ---------- Header fields ---------- */

    const prnumber = getAnswerByName(answers, "prNumber");
    const requesttype = getAnswerByName(answers, "typeA78");
    const branchRaw = getAnswerByName(answers, "centerName");
    const vendor = getAnswerByName(answers, "vendor");
    const vin = getAnswerByName(answers, "vin");
    const rawBrandClass = getAnswerByName(answers, "partsBrand119");
    const brandclass = Array.isArray(rawBrandClass)? rawBrandClass[0] ?? null: typeof rawBrandClass === "string"? rawBrandClass: null;
    const makeModel = getAnswerByName(answers, "typeA121");
    const year = getAnswerByName(answers, "typeA122");

    /* ✅ FIX: Extract make & model from string */
    let carMake: string | null = null;
    let carModel: string | null = null;

    if (typeof makeModel === "string") {
    const parts = makeModel.split(".");

    carMake = parts[0]?.trim() || null;
    carModel = parts[1]?.trim() || null;
   }
   console.log("🚗 Raw makeModel:", makeModel);
   console.log("🚗 Car Make:", carMake);
   console.log("🚗 Car Model:", carModel);
    const preparedBy = getAnswerByName(answers, "preparedBy");
    const email = getAnswerByName(answers, "email");
    const mobileRaw = getAnswerByName(answers, "mobileNumber");
    const mobile = mobileRaw && typeof mobileRaw === "object" ? mobileRaw.full ?? null : mobileRaw ?? null;
    console.log("📱 Normalized mobile:", mobile);
    const serviceAdvisor =
      preparedBy && typeof preparedBy === "object"
        ? `${preparedBy.first ?? ""} ${preparedBy.last ?? ""}`.trim()
        : null;
    const plate = getAnswerByName(answers, "plate");
    const platenumber =
      plate && typeof plate === "object"
        ? `${plate.first ?? ""} ${plate.last ?? ""}`.trim()
        : null;
    const fileUploadRaw = getAnswerByName(answers, "fileUpload");
    console.log("📎 Raw fileUpload answer:", fileUploadRaw);
    // Normalize to array
    const fileUrls: string[] = Array.isArray(fileUploadRaw) ? fileUploadRaw: fileUploadRaw ? [fileUploadRaw]: [];    
    const orderDate = apiData.content.created_at
      ? new Date(
          new Date(apiData.content.created_at).getTime() +
            8 * 60 * 60 * 1000 // KSA
        ).toISOString()
      : null;
    /* ---------- Vendor filter ---------- */
    const normalizeVendor = (v: string) =>
   v
    .trim()
    .replace(/\s+/g, " ")
    .replace(/[–—]/g, "-")
    .normalize("NFKC");

    const ALLOWED_VENDOR = normalizeVendor(
    "Q-Parts - شركة تطبيق قطع للتجارة"
   );

   const normalizedVendor = vendor
   ? normalizeVendor(vendor)
   : null;

   console.log("🧾 Vendor from form (normalized):", normalizedVendor);

   if (!normalizedVendor || normalizedVendor !== ALLOWED_VENDOR) {
    console.log("⛔ Ignored vendor (mismatch):", {
    received: vendor,
    normalized: normalizedVendor,
    expected: ALLOWED_VENDOR
    });

   return new Response(
    JSON.stringify({
      ok: true,
      ignored: true,
      reason: "Vendor not allowed",
      vendor
    }),
    { status: 200 }
   );
   }

    /* ---------- Resolve client & order numbering ---------- */

    const branchCode = `C-${branchRaw}`;
    console.log("🏢 Branch from form:", branchRaw);
    console.log("🏢 Normalized branch code:", branchCode);

    const { data: branchMap, error: branchErr } = await supabase
    .from("clients_branches")
    .select("caraagy_east, caraagy_west, caraagy_riyadh")
    .limit(1)
    .single();

   console.log("🧪 client_branches query result:", {
   data: branchMap,
   error: branchErr
   });

    let clientName: string;
    let orderNumber: string;

    // Check Caraagy West
    const { data: westMatch } = await supabase
    .from("clients_branches")
    .select("caraagy_west")
    .eq("caraagy_west", branchCode)
    .maybeSingle();

    if (westMatch) {
    clientName = "Caraagy West";
    ({ data: orderNumber } = await supabase.rpc(
    "get_next_caraagy_west_order_number"
    ));
   console.log("✅ Branch matched Caraagy West");
   }

   // Check Caraagy East
   else {
   const { data: eastMatch } = await supabase
    .from("clients_branches")
    .select("caraagy_east")
    .eq("caraagy_east", branchCode)
    .maybeSingle();

    if (eastMatch) {
    clientName = "Caraagy East";
    ({ data: orderNumber } = await supabase.rpc(
      "get_next_caraagy_east_order_number"
    ));
    console.log("✅ Branch matched Caraagy East");
   }

   // Check Caraagy Riyadh
   else {
    const { data: riyadhMatch } = await supabase
      .from("clients_branches")
      .select("caraagy_riyadh")
      .eq("caraagy_riyadh", branchCode)
      .maybeSingle();

    if (riyadhMatch) {
      clientName = "Caraagy Riyadh";
      ({ data: orderNumber } = await supabase.rpc(
        "get_next_caraagy_riyadh_order_number"
      ));
      console.log("✅ Branch matched Caraagy Riyadh");
    } else {
      console.log("⛔ Branch not mapped:", branchCode);
      return new Response(
        JSON.stringify({
          ok: true,
          ignored: true,
          reason: "Branch not mapped",
          branch: branchCode
        }),
        { status: 200 }
      );
     }
   }
  }

    console.log("🏷 Client name:", clientName);
    console.log("🔢 Order number:", orderNumber);

    console.log("🔢 Order number generated:", orderNumber);

    /* ---------- Account manager ---------- */

    let accountManager: string | null = null;

    if (branchCode && orderDate) {
      const slot = getSlotFromDate(orderDate);
      const weekday = getWeekdayColumn(orderDate);

      if (slot && weekday) {
        const { data } = await supabase
          .from("account_manager_slots")
          .select(weekday)
          .eq("client", branchCode)
          .eq("slot", slot)
          .limit(1)
          .single();

        accountManager = data?.[weekday] ?? null;
      }
    }

    /* ---------- Extract items ---------- */

    const matrixField = findFieldByTypeAndName(
      answers,
      "control_matrix",
      "items"
    );

    if (!matrixField?.answer) {
      return new Response(JSON.stringify({ ok: false }), { status: 400 });
    }

    const rows: any[] = [];
    let index = 0;

    for (const raw of Object.values(matrixField.answer)) {
      if (!raw) continue;

      let parsed: string[];
      try {
        parsed = JSON.parse(raw as string);
      } catch {
        continue;
      }

      if (parsed.every(v => !v || v.trim() === "")) continue;

      index += 1;
      console.log("🗄 submission_date to be saved:", orderDate);

      rows.push({
        submission_id: submissionId,
        order_number: orderNumber,
        line_item_code: `${orderNumber}-${index}`,
        status: "Placed Order",
        client_name: clientName,
        delivery_type: "Next Working Slot",
        vin,
        brand_class: brandclass,
        main_brand:carMake,
        model: carModel,
        plate_number: platenumber,
        notes: [requesttype, prnumber, year ? `model year ${year}` : null].filter(Boolean).join(" - "),
        branch: branchCode,
        account_manager: accountManager,
        service_advisor: serviceAdvisor,
        email_1: mobile ? `${email}-${mobile}` : email,
        submission_date: orderDate,
        part_photo: fileUrls.length ? fileUrls : null,

        part_number: parsed[0] ?? null,
        part_description: parsed[1] ?? null,
        quantity: parsed[3] ? Number(parsed[3]) : null
      });
    }

    if (!rows.length) {
      return new Response(JSON.stringify({ ok: true, items_inserted: 0 }), {
        status: 200
      });
    }

    /* ---------- Insert ---------- */

    const { error } = await supabase.from("all_orders").insert(rows);

    if (error) {
      console.log("❌ DB error:", error);
      return new Response(JSON.stringify({ ok: false }), { status: 500 });
    }

    return new Response(
      JSON.stringify({
        ok: true,
        order_number: orderNumber,
        items_inserted: rows.length
      }),
      { status: 200 }
    );
  } catch (err: any) {
    console.log("❌ ERROR:", err);
    return new Response(
      JSON.stringify({ ok: false, error: err.message }),
      { status: 400 }
    );
  }
});
