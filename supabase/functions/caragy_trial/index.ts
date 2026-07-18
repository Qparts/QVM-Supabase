import { serve } from "https://deno.land/std/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js";

serve(async (req: Request): Promise<Response> => {
  try {
    const formData = await req.formData();

    // Extract submission ID
    let submissionId =
      formData.get("submissionID")?.toString() ??
      formData.get("id")?.toString() ??
      null;

    if (!submissionId) {
      console.log("❌ No submission ID found");
      return new Response(JSON.stringify({ ok: false }), { status: 400 });
    }

    console.log("📌 SUBMISSION ID:", submissionId);

    // Load secrets
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const JF_KEY = Deno.env.get("JOTFORM_API_KEY")!;

    // Fetch full submission from Jotform
    const apiUrl = `https://api.jotform.com/submission/${submissionId}?apiKey=${JF_KEY}`;
    console.log("📌 API URL:", apiUrl);

    const apiResp = await fetch(apiUrl);
    const apiData = await apiResp.json();

    console.log("📌 FULL RESPONSE:", apiData);

    if (!apiData.content) {
      return new Response(JSON.stringify({ ok: false, err: "No content" }), {
        status: 400,
      });
    }

    const answers = apiData.content.answers;

    // Header (same for every line item)
    const branch = answers["3"]?.answer ?? null;
    const vin = answers["4"]?.answer ?? null;
    const mainBrand = answers["113"]?.answer ?? null;
    const deliveryType = answers["112"]?.answer ?? null;
    const poNumber = answers["107"]?.answer ?? null;
    const neededItems = answers["8"]?.answer
      ? Number(answers["8"].answer)
      : null;

    console.log("📌 BRANCH:", branch);

    // Optional branch filter
    const allowedBranches = ["Prince Majid Street"];
    if (!allowedBranches.includes(branch)) {
      console.log("⛔ Ignored branch:", branch);
      return new Response(JSON.stringify({ ok: true, ignored: true }), {
        status: 200,
      });
    }

    // Extract all parts (dynamic)
    const parts: any[] = [];

    for (const key in answers) {
      const item = answers[key];

      if (item.name.startsWith("partDescription") && item.answer) {
        const idx = item.name.replace("partDescription", "");

        parts.push({
          description: item.answer ?? null,
          partnumber: answers[`partNumber${idx}`]?.answer ?? null,
          quantity: answers[`quantity${idx}`]?.answer
            ? Number(answers[`quantity${idx}`].answer)
            : null,
          brand_class: answers[`brandClass${idx}`]?.answer ?? null,
          photo: answers[`partPhoto${idx}`]?.answer?.[0] ?? null,
        });
      }
    }

    console.log("📌 PARTS FOUND:", parts.length);

    // Build rows for Supabase insert
    const rows = parts.map((p) => ({
      submission_id: submissionId,
      branch,
      vin,
      main_brand: mainBrand,
      delivery_type: deliveryType,
      po_number: poNumber,
      needed_items: neededItems,

      part_description: p.description,
      part_number: p.partnumber,
      quantity: p.quantity,
      brand_class: p.brand_class,
      part_photo: p.photo,

      raw_payload: apiData.content, // store once, duplicates ok
    }));

    console.log("📌 ROWS TO INSERT:", rows.length);

    const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

    const { error } = await supabase.from("jotform_orders_test").insert(rows);

    if (error) {
      console.log("❌ DB error:", error);
      return new Response(JSON.stringify({ ok: false, error }), {
        status: 500,
      });
    }

    return new Response(JSON.stringify({ ok: true, items_inserted: rows.length }), {
      status: 200,
    });
  } catch (err) {
    console.log("❌ ERROR:", err);
    return new Response(JSON.stringify({ ok: false, error: err.message }), {
      status: 400,
    });
  }
});
