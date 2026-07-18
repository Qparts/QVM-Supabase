import { serve } from "https://deno.land/std/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js";

serve(async (req) => {
  try {
    console.log("SERVICE ROLE KEY EXISTS:", !!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    console.log("SERVICE ROLE KEY PREFIX:", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.slice(0, 20));
    const { customer_id } = await req.json();

    if (!customer_id) {
      return jsonResponse(false, "customer_id is required", null, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const slot = getSlotNumber();
    const day = getDayColumn();

    /* 1️⃣ Primary allocation */
    const { data: allocation } = await supabase
      .rpc('get_account_manager_allocation', {
        customer_id_param: customer_id,
        slot_param: slot
      })
      .single();


    if (!allocation) {
      return jsonResponse(false, "No account manager allocation found", null, 404);
    }

    let candidates: string[] = [];

    if (allocation[day]) {
      candidates.push(allocation[day]);
    }

    /* 2️⃣ Branch fallback chain */
    const { data: branch , error} = await supabase
      .rpc('get_account_manager_branch', {
        p_customer_id: customer_id,
        p_slot_number: slot
      })
      .single();

    if (branch) {
      candidates.push(
        branch.main_account_manager,
        branch.first_substitute,
        branch.second_substitute,
        branch.fallback_account_manager
      );
    }

    /* Remove nulls & duplicates */
    candidates = [...new Set(candidates.filter(Boolean))];
    console.log(candidates, branch, error);
    /* 3️⃣ Evaluate candidates */
    for (const manager of candidates) {
      const activeCount = await getActiveCount(supabase, manager);
      if (activeCount > 7) continue;

      const available = await isAvailable(supabase, manager, slot, day);
      if (!available) continue;

      return jsonResponse(
        true,
        "Account manager assigned successfully",
        { account_manager: manager },
        200
      );
    }

    return jsonResponse(false, "No available account manager", null, 409);

  } catch (err) {
    return jsonResponse(false, err.message, null, 500);
  }
});

/* ================= HELPERS ================= */

function jsonResponse(
  status: boolean,
  message: string,
  data: any,
  code = 200
) {
  return new Response(
    JSON.stringify({ status, message, data }),
    {
      status: code,
      headers: { "Content-Type": "application/json" }
    }
  );
}

function getSlotNumber(): number {
  const now = new Date(
    new Date().toLocaleString("en-US", { timeZone: "Asia/Riyadh" })
  );
  const minutes = now.getHours() * 60 + now.getMinutes();

  if (minutes >= 21 * 60 || minutes <= 12 * 60 + 59) return 1;
  if (minutes >= 13 * 60 && minutes <= 16 * 60 + 59) return 2;
  return 3;
}

function getDayColumn(): string {
  return new Date(
    new Date().toLocaleString("en-US", { timeZone: "Asia/Riyadh" })
  )
    .toLocaleDateString("en-US", { weekday: "long" })
    .toLowerCase();
}

async function getActiveCount(
  supabase: any,
  manager: string
): Promise<number> {
  const { data, error } = await supabase
    .rpc('count_active_rfq_orders', { p_account_manager: manager });
  if (error) throw error;
  return data ?? 0;
}

async function isAvailable(
  supabase: any,
  manager: string,
  slot: number,
  day: string
): Promise<boolean> {
  const { data } = await supabase
    .rpc('get_available_manager_slot', {
      p_manager_id: manager,
      p_slot_number: slot,
      p_day: day
    })
    .maybeSingle();

  return !!data;
}
