import { serve } from "https://deno.land/std/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js";

/* ---------- Helpers ---------- */

function getAnswerByName(
  answers: Record<string, any>,
  fieldName: string
) {
  return (
    Object.values(answers).find(
      (a: any) => a.name === fieldName
    )?.answer ?? null
  );
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

// Slot logic (matches your SQL)
function getSlotFromDate(dateStr: string): number | null {
  const d = new Date(dateStr);
  const h = d.getHours();

  if (h >= 21 || h < 13) return 1;
  if (h >= 13 && h < 17) return 2;
  if (h >= 17 && h < 21) return 3;

  return null;
}

// Weekday column (monday, tuesday, ...)
function getWeekdayColumn(dateStr: string): string {
  return new Date(dateStr)
    .toLocaleDateString("en-US", { weekday: "long" })
    .toLowerCase();
}

/* ---------- Function ---------- */

serve(async (req: Request): Promise<Response> => {
  try {
    /* 1️⃣ Read multipart form (Settings → Webhooks only) */
    const formData = await req.formData();

    const submissionId =
      formData.get("submissionID")?.toString() ??
      formData.get("id")?.toString() ??
      null;

    if (!submissionId) {
      console.log("❌ No submission ID");
      return new Response(JSON.stringify({ ok: false }), { status: 400 });
    }

    /* 2️⃣ Secrets */
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const JF_KEY = Deno.env.get("Caragytest_API_KEY")!;

    const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_KEY);

    /* 3️⃣ Fetch full submission from Jotform */
    const apiUrl = `https://api.jotform.com/submission/${submissionId}?apiKey=${JF_KEY}`;
    const apiResp = await fetch(apiUrl);
    const apiData = await apiResp.json();

    if (!apiData?.content?.answers) {
      console.log("❌ No answers returned");
      return new Response(JSON.stringify({ ok: false }), { status: 400 });
    }

    const answers = apiData.content.answers;
    const orderDate = apiData.content.created_at;

    /* 4️⃣ Header fields (by UNIQUE NAME) */
    const vin = getAnswerByName(answers, "input7");
    const plate = getAnswerByName(answers, "input8");
    const mainBrand = getAnswerByName(answers, "input9");
    const model = getAnswerByName(answers, "input10");
    const branch = getAnswerByName(answers, "centerName");

    /* 5️⃣ Generate order number (ONCE per submission) */
    const { data: orderNumber, error: orderErr } =
      await supabaseAdmin.rpc("get_next_caragy_order_number");

    if (orderErr || !orderNumber) {
      console.log("❌ Order number generation failed", orderErr);
      return new Response(JSON.stringify({ ok: false }), { status: 500 });
    }

    /* 6️⃣ Determine account manager */
    let accountManager: string | null = null;

    if (branch && orderDate) {
      const slot = getSlotFromDate(orderDate);
      const weekday = getWeekdayColumn(orderDate);

      if (slot && weekday) {
        const { data: slotRow, error: slotErr } =
          await supabaseAdmin
            .from("account_manager_slots")
            .select(weekday)
            .eq("client", branch)
            .eq("slot", slot)
            .limit(1)
            .single();

        if (!slotErr) {
          accountManager = slotRow?.[weekday] ?? null;
        }
      }
    }

    /* 7️⃣ Extract MATRIX items */
    const matrixField = findFieldByTypeAndName(
      answers,
      "control_matrix",
      "typeA"
    );

    if (!matrixField?.answer) {
      console.log("❌ Matrix field not found");
      return new Response(JSON.stringify({ ok: false }), { status: 400 });
    }

    /* 8️⃣ Build rows */
    const rows: any[] = [];
    let itemIndex = 0;

    for (const rawRow of Object.values(matrixField.answer)) {
      if (!rawRow) continue;

      let parsed: string[];
      try {
        parsed = JSON.parse(rawRow as string);
      } catch {
        continue;
      }

      if (parsed.every(v => !v || v.trim() === "")) continue;

      itemIndex += 1;

      rows.push({
        submission_id: submissionId,
        order_number: orderNumber,
        line_item_code: `${orderNumber}-${itemIndex}`,
        status: "Placed Order",
        client_name: "Caragy",

        branch,
        account_manager: accountManager,
        vin,
        plate,
        main_brand: mainBrand,
        model,
        order_date: orderDate,

        part_description: parsed[0] ?? null,
        part_number: parsed[1] ?? null,
        quantity: parsed[2] ? Number(parsed[2]) : null,

        raw_payload: apiData.content
      });
    }

    if (!rows.length) {
      return new Response(
        JSON.stringify({ ok: true, items_inserted: 0 }),
        { status: 200 }
      );
    }

    /* 9️⃣ Insert rows */
    const { error: insertErr } =
      await supabaseAdmin
        .from("jotform_orders_test")
        .insert(rows);

    if (insertErr) {
      console.log("❌ DB error:", insertErr);
      return new Response(JSON.stringify({ ok: false }), { status: 500 });
    }

    return new Response(
      JSON.stringify({
        ok: true,
        order_number: orderNumber,
        items_inserted: rows.length,
        account_manager: accountManager
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
