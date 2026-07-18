import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import OpenAI from "https://esm.sh/openai@4.0.0";
const openai = new OpenAI({
  apiKey: "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"
});
serve(async (req)=>{
  try {
    const { prompt, file_url } = await req.json();
    if (!prompt || !file_url) {
      return new Response(JSON.stringify({
        error: "Missing prompt or file_url"
      }), {
        status: 400
      });
    }
    // 1. Fetch file from the given URL
    const fileRes = await fetch(file_url);
    if (!fileRes.ok) {
      return new Response(JSON.stringify({
        error: "Unable to fetch file",
        details: await fileRes.text()
      }), {
        status: fileRes.status
      });
    }
    const fileText = await fileRes.text();
    const completion = await openai.chat.completions.create({
      model: "gpt-4.1",
      temperature: 0,
      messages: [
        {
          role: "system",
          content: `${prompt}`
        },
        {
          role: "user",
          content: `Here is the OCR text extracted from the invoice:\n\nFile contents:\n${fileText}`
        }
      ]
    });
    const result = completion.choices[0].message?.content;
    // 4. Return result
    return new Response(JSON.stringify({
      result
    }), {
      status: 200,
      headers: {
        "Content-Type": "application/json"
      }
    });
  } catch (err) {
    console.error("Process error:", err);
    return new Response(JSON.stringify({
      error: err.message
    }), {
      status: 500
    });
  }
});
