import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  // Handle CORS preflight requests
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { html, filename } = await req.json()

    if (!html) {
      return new Response(
        JSON.stringify({ error: 'HTML content is required' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      )
    }

    // For now, return the HTML with proper headers that will allow browser to save as PDF
    // This is a temporary solution until we implement proper PDF generation
    const pdfHtml = `
      <!DOCTYPE html>
      <html>
      <head>
        <meta charset="utf-8">
        <title>${filename || 'quotation'}</title>
        <style>
          @page {
            margin: 20mm;
            size: A4;
          }
          body {
            font-family: 'Lora', serif;
            margin: 0;
            color: #2c3e50;
            background: #f8f9fa;
          }
          @media print {
            body {
              margin: 0;
              background: white;
              -webkit-print-color-adjust: exact;
              print-color-adjust: exact;
            }
            .header {
              background: white !important;
              color: #2c3e50 !important;
              border-bottom: 3px solid #e74c3c !important;
              -webkit-print-color-adjust: exact;
            }
            th {
              background: white !important;
              color: #2c3e50 !important;
              -webkit-print-color-adjust: exact;
            }
          }
        </style>
      </head>
      <body>
        ${html}
      </body>
      </html>
    `

    // Return as HTML file that can be saved and printed to PDF
    return new Response(pdfHtml, {
      headers: {
        ...corsHeaders,
        'Content-Type': 'text/html',
        'Content-Disposition': `attachment; filename="${filename || 'quotation.html'}"`
      }
    })

  } catch (error) {
    console.error('PDF generation error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to generate PDF', details: error.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
