import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { messages } = await req.json();
    const LOVABLE_API_KEY = Deno.env.get("LOVABLE_API_KEY");
    
    if (!LOVABLE_API_KEY) {
      throw new Error("LOVABLE_API_KEY is not configured");
    }

    const systemPrompt = `You are an AI assistant helping users fill out an RFQ (Request for Quotation) form for auto parts.

The user has been guided through the form fields step by step and has provided their responses. Your job is to extract the structured form data from the conversation.

When the user has finished providing all the information (including parts details), use the extract_form_data function to return the structured data.

The form requires:
- Client Name (required)
- Branch (required, depends on client)
- Plate Number (optional)
- VIN (optional, must be 17 characters if provided)
- Main Brand (required)
- Model (optional)
- All Items Required (required: one of Genuine, OEM, Aftermarket, Used, Mixed)
- Parts List (array of parts):
  * IMPORTANT: Each part must have EITHER description OR partNumber (or both), but at least one is required
  * Quantity is required (must be a positive number)
  * Brand class is ONLY required if "All Items Required" is "Mixed", otherwise it should be omitted

Extract the information from the conversation and call the extract_form_data function with all the collected data.`;

    const response = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${LOVABLE_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-flash",
        messages: [
          { role: "system", content: systemPrompt },
          ...messages,
        ],
        tools: [
          {
            type: "function",
            function: {
              name: "extract_form_data",
              description: "Extract form field values from the conversation",
              parameters: {
                type: "object",
                properties: {
                  clientName: { type: "string" },
                  branch: { type: "string" },
                  plateNumber: { type: "string" },
                  vin: { type: "string" },
                  mainBrand: { type: "string" },
                  model: { type: "string" },
                  allItemsRequired: { 
                    type: "string",
                    enum: ["Genuine", "OEM", "Aftermarket", "Used", "Mixed"]
                  },
                  parts: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                        description: { type: "string" },
                        partNumber: { type: "string" },
                        qty: { type: "number" },
                        brandClass: { type: "string" }
                      }
                    }
                  }
                },
                additionalProperties: false
              }
            }
          }
        ],
        tool_choice: "auto"
      }),
    });

    if (!response.ok) {
      if (response.status === 429) {
        return new Response(JSON.stringify({ error: "Rate limits exceeded, please try again later." }), {
          status: 429,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (response.status === 402) {
        return new Response(JSON.stringify({ error: "Payment required, please add funds to your Lovable AI workspace." }), {
          status: 402,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      const errorText = await response.text();
      console.error("AI gateway error:", response.status, errorText);
      return new Response(JSON.stringify({ error: "AI gateway error" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const data = await response.json();
    
    return new Response(JSON.stringify(data), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("chat error:", e);
    return new Response(JSON.stringify({ error: e instanceof Error ? e.message : "Unknown error" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
