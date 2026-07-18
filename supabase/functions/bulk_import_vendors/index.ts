// DISABLED. One-off vendor bulk-import utility, retired after use.
Deno.serve(() => new Response(JSON.stringify({ status: "gone", message: "This one-off utility has been retired." }), { status: 410, headers: { "Content-Type": "application/json" } }));
