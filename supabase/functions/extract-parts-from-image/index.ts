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
    const { image } = await req.json();

    if (!image) {
      return new Response(
        JSON.stringify({ error: 'No image provided' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const LOVABLE_API_KEY = Deno.env.get('LOVABLE_API_KEY');
    if (!LOVABLE_API_KEY) {
      console.error('LOVABLE_API_KEY is not configured');
      return new Response(
        JSON.stringify({ error: 'API key not configured' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const systemPrompt = `You are an AI assistant that extracts automotive parts information from images.
Analyze the provided image and extract information about automotive parts.
Look for:
- Part descriptions (e.g., "Brake Pad", "Oil Filter", "Air Filter")
- Part numbers (manufacturer part numbers or OEM numbers)
- Quantities (if specified)
- Any brand or quality class information

Return the extracted parts data using the extract_parts function.
If you cannot clearly identify parts information in the image, return an empty parts array.`;

    console.log('Calling Lovable AI Gateway for image analysis...');

    const response = await fetch('https://ai.gateway.lovable.dev/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${LOVABLE_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'google/gemini-2.5-flash',
        messages: [
          {
            role: 'system',
            content: systemPrompt
          },
          {
            role: 'user',
            content: [
              {
                type: 'text',
                text: 'Please analyze this image and extract all automotive parts information you can find.'
              },
              {
                type: 'image_url',
                image_url: {
                  url: image
                }
              }
            ]
          }
        ],
        tools: [
          {
            type: 'function',
            function: {
              name: 'extract_parts',
              description: 'Extract automotive parts information from the image',
              parameters: {
                type: 'object',
                properties: {
                  parts: {
                    type: 'array',
                    items: {
                      type: 'object',
                      properties: {
                        description: {
                          type: 'string',
                          description: 'Description of the part (e.g., "Front Brake Pad", "Engine Oil Filter")'
                        },
                        partNumber: {
                          type: 'string',
                          description: 'Part number or OEM number if visible'
                        },
                        qty: {
                          type: 'number',
                          description: 'Quantity needed (default to 1 if not specified)'
                        },
                        brandClass: {
                          type: 'string',
                          description: 'Brand class if specified (Genuine, OEM, Aftermarket, or Used)',
                          enum: ['Genuine', 'OEM', 'Aftermarket', 'Used']
                        }
                      },
                      required: ['description', 'partNumber', 'qty']
                    }
                  }
                },
                required: ['parts']
              }
            }
          }
        ],
        tool_choice: {
          type: 'function',
          function: { name: 'extract_parts' }
        }
      }),
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error('AI Gateway error:', response.status, errorText);
      
      if (response.status === 429) {
        return new Response(
          JSON.stringify({ error: 'Rate limit exceeded. Please try again later.' }),
          { status: 429, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }
      
      if (response.status === 402) {
        return new Response(
          JSON.stringify({ error: 'Payment required. Please add credits to your Lovable workspace.' }),
          { status: 402, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
        );
      }

      return new Response(
        JSON.stringify({ error: 'Failed to process image' }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    const data = await response.json();
    console.log('AI response:', JSON.stringify(data, null, 2));

    const toolCalls = data.choices?.[0]?.message?.tool_calls;
    if (toolCalls && toolCalls.length > 0) {
      const extractedData = JSON.parse(toolCalls[0].function.arguments);
      console.log('Extracted parts:', extractedData);
      
      return new Response(
        JSON.stringify(extractedData),
        { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    }

    return new Response(
      JSON.stringify({ parts: [] }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );

  } catch (error) {
    console.error('Error in extract-parts-from-image:', error);
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Unknown error' }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    );
  }
});
