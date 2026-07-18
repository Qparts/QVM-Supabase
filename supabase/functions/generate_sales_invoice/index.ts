import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type JsonRecord = Record<string, unknown>;

type ZohoItem = {
  item_id: string;
  sku?: string | null;
  account_id?: string | null;
  sales_account_id?: string | null;
  purchase_account_id?: string | null;
  inventory_account_id?: string | null;
};

type InvoiceResult = {
  invoice_id: string;
  invoice_number?: string | null;
  invoice_url?: string | null;
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SPECIAL_CC_CLIENTS = new Set([
  "caraagy west",
  "lease east",
  "lease west",
  "lease central",
  "lease south",
  "petromin riyadh",
  "petromin west",
  "petromin - body & paint",
  "pit stop",
  "tawuniya",
]);

const SPECIAL_CC_EMAIL = "abdulrahman@qparts.co";

const BRAND_CLASS_SUFFIX: Record<string, string> = {
  genuine: "G",
  oem: "O",
  aftermarket: "A",
  used: "U",
};

const safeNumber = (value: unknown) => {
  const num = Number(value);
  return Number.isFinite(num) ? num : 0;
};

const uniqueStrings = (values: (string | null | undefined)[]) => {
  const set = new Set<string>();

  for (const value of values) {
    if (value && value.trim()) set.add(value.trim());
  }

  return Array.from(set);
};

const buildSku = (partNumber: string, brandClass?: string | null) => {
  const key = String(brandClass || "").trim().toLowerCase();
  const suffix = BRAND_CLASS_SUFFIX[key] ?? "A";
  return `${partNumber}(N${suffix})`;
};

const normalizeOrderNumber = (value: unknown) =>
  String(value ?? "")
    .trim()
    .toLowerCase()
    .replace(/\s+/g, "");

const getZohoToken = async () => {
  const clientId = Deno.env.get("ZOHO_CLIENT_ID") ?? "";
  const clientSecret = Deno.env.get("ZOHO_CLIENT_SECRET") ?? "";
  const refreshToken = Deno.env.get("ZOHO_REFRESH_TOKEN") ?? "";
  const accountsBase = Deno.env.get("ZOHO_ACCOUNTS_BASE") ?? "https://accounts.zoho.com";

  if (!clientId || !clientSecret || !refreshToken) {
    throw new Error("Missing Zoho OAuth env vars");
  }

  const params = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: clientId,
    client_secret: clientSecret,
    refresh_token: refreshToken,
  });

  const res = await fetch(`${accountsBase}/oauth/v2/token?${params.toString()}`, {
    method: "POST",
  });

  const data = await res.json();

  if (!res.ok) {
    throw new Error(`Failed to refresh Zoho token: ${JSON.stringify(data)}`);
  }

  return data.access_token as string;
};

const zohoRequest = async (token: string, path: string, init?: RequestInit) => {
  const apiBase = Deno.env.get("ZOHO_BOOKS_API_BASE") ?? "https://www.zohoapis.com/books/v3";
  const orgId = Deno.env.get("ZOHO_ORG_ID") ?? "";

  if (!orgId) throw new Error("Missing ZOHO_ORG_ID env var");

  const url = new URL(`${apiBase}${path}`);
  url.searchParams.set("organization_id", orgId);

  const res = await fetch(url.toString(), {
    ...init,
    headers: {
      Authorization: `Zoho-oauthtoken ${token}`,
      "Content-Type": "application/json",
      ...(init?.headers || {}),
    },
  });

  const data = await res.json();

  if (!res.ok || (data?.code && data?.code !== 0 && data?.code !== "0")) {
    throw new Error(`Zoho error (${path}): ${JSON.stringify(data)}`);
  }

  return data;
};

serve(async (req) => {
  // ✅ STEP 0 — Handle CORS preflight request
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // ✅ STEP 1 — Read and validate request payload
    const { p_order_number } = await req.json();
    const orderNumber = String(p_order_number || "").trim();

    if (!orderNumber) {
      return new Response(
        JSON.stringify({
          status: false,
          message: "Order number is required",
        }),
        {
          status: 400,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // ✅ STEP 2 — Load required Supabase environment variables
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    if (!supabaseUrl || !supabaseAnonKey || !serviceKey) {
      throw new Error("Missing Supabase env vars");
    }

    console.log("generate_sales_invoice started", {
      supabaseUrl,
      orderNumber,
    });

    // ✅ STEP 3 — Validate authenticated user
    const authHeader = req.headers.get("Authorization") ?? "";

    const supabaseAuth = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });

    const { data: userRes, error: userErr } = await supabaseAuth.auth.getUser();

    if (userErr || !userRes?.user) {
      return new Response(
        JSON.stringify({
          status: false,
          message: "Unauthorized",
        }),
        {
          status: 401,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // ✅ STEP 4 — Create service-role Supabase client
    const supabase = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false },
    }).schema("qvm_new_apps");

    // ✅ STEP 5 — Find quotation/order safely by order number
    const { data: quotationMatches, error: quotationErr } = await supabase
      .from("quotations")
      .select("quotation_id, order_number, plate_number, shipping_price, account_manager, created_at")
      .ilike("order_number", `%${orderNumber}%`)
      .order("created_at", { ascending: false })
      .limit(10);

    if (quotationErr) {
      throw new Error(`Quotation lookup failed: ${JSON.stringify(quotationErr)}`);
    }

    const quotation =
      (quotationMatches ?? []).find(
        (q) => normalizeOrderNumber(q.order_number) === normalizeOrderNumber(orderNumber),
      ) ?? quotationMatches?.[0];

    if (!quotation) {
      throw new Error(`Order not found in quotations. Received orderNumber=${JSON.stringify(orderNumber)}`);
    }

    // ✅ STEP 6 — Find confirmed order
    const { data: confirmedOrders, error: confirmedErr } = await supabase
      .from("confirmed_orders")
      .select("confirmed_order_id, quotation_id")
      .eq("quotation_id", quotation.quotation_id)
      .order("created_at", { ascending: false })
      .limit(1);

    if (confirmedErr) {
      throw new Error(`Confirmed order lookup failed: ${JSON.stringify(confirmedErr)}`);
    }

    const confirmedOrder = confirmedOrders?.[0];

    if (!confirmedOrder) {
      throw new Error(`Confirmed order not found for quotation_id=${quotation.quotation_id}`);
    }

    const confirmedOrderId = confirmedOrder.confirmed_order_id as number;

    // ✅ STEP 7 — Load deliveries
    const { data: deliveries, error: deliveriesErr } = await supabase
      .from("deliveries")
      .select("delivery_id, shipping_price, shipping_cost, delivery_date")
      .eq("confirmed_order_id", confirmedOrderId);

    if (deliveriesErr) throw deliveriesErr;

    const deliveryIds = (deliveries ?? [])
      .map((d) => d.delivery_id)
      .filter(Boolean);

    if (!deliveryIds.length) {
      throw new Error("No delivery note found for this confirmed order");
    }

    // ✅ STEP 8 — Load delivery-note line items
    const { data: deliveryItems, error: deliveryItemsErr } = await supabase
      .from("delivery_items")
      .select("delivery_item_id, delivery_id, confirmed_item_id, delivered_qty, invoice_id")
      .in("delivery_id", deliveryIds);

    if (deliveryItemsErr) throw deliveryItemsErr;

    if (!deliveryItems?.length) {
      throw new Error("No delivery items found for this delivery note");
    }

    const currentDeliveryItemIds = (deliveryItems ?? [])
      .map((item) => item.delivery_item_id)
      .filter(Boolean);

    const confirmedItemIdsFromDelivery = (deliveryItems ?? [])
      .map((item) => item.confirmed_item_id)
      .filter(Boolean);

    // ✅ STEP 9 — Check invoices table first
    const { data: existingOrderInvoices, error: existingOrderInvoiceErr } = await supabase
      .from("invoices")
      .select("invoice_id, invoice_number, invoice_url")
      .eq("confirmed_order_id", confirmedOrderId)
      .order("created_at", { ascending: false });

    if (existingOrderInvoiceErr) throw existingOrderInvoiceErr;

    // ✅ STEP 10 — If invoice exists, verify same delivery-note items are linked to that invoice
    if (existingOrderInvoices?.length) {
      const existingInvoiceIds = existingOrderInvoices
        .map((invoice) => invoice.invoice_id)
        .filter(Boolean);

      const { data: alreadyInvoicedDeliveryItems, error: alreadyInvoicedDeliveryItemsErr } =
        await supabase
          .from("delivery_items")
          .select("delivery_item_id, confirmed_item_id, invoice_id")
          .in("delivery_item_id", currentDeliveryItemIds)
          .in("invoice_id", existingInvoiceIds);

      if (alreadyInvoicedDeliveryItemsErr) throw alreadyInvoicedDeliveryItemsErr;

      const alreadyInvoicedDeliveryItemIds = new Set(
        (alreadyInvoicedDeliveryItems ?? []).map((item) => item.delivery_item_id),
      );

      const allCurrentItemsAlreadyInvoiced = currentDeliveryItemIds.every((deliveryItemId) =>
        alreadyInvoicedDeliveryItemIds.has(deliveryItemId)
      );

      if (allCurrentItemsAlreadyInvoiced) {
        const matchedInvoiceId = alreadyInvoicedDeliveryItems?.[0]?.invoice_id;

        const matchedInvoice =
          existingOrderInvoices.find((invoice) => invoice.invoice_id === matchedInvoiceId) ??
          existingOrderInvoices[0];

        return new Response(
          JSON.stringify({
            status: true,
            message: "Invoice already exists for the same delivery note items",
            invoice_id: matchedInvoice.invoice_id,
            invoice_number: matchedInvoice.invoice_number,
            invoice_url: matchedInvoice.invoice_url,
          }),
          {
            status: 200,
            headers: { ...corsHeaders, "Content-Type": "application/json" },
          },
        );
      }
    }

    // ✅ STEP 11 — Load confirmed items from delivery note only
    const { data: confirmedItems, error: confirmedItemsErr } = await supabase
      .from("confirmed_items")
      .select("confirmed_item_id, quotation_item_id, final_part_number, approved_qty, final_brand_class, item_status")
      .in("confirmed_item_id", confirmedItemIdsFromDelivery.length ? confirmedItemIdsFromDelivery : [-1]);

    if (confirmedItemsErr) throw confirmedItemsErr;

    if (!confirmedItems?.length) {
      throw new Error("No confirmed items found for delivery note line items");
    }

    const quotationItemIds = (confirmedItems ?? [])
      .map((i) => i.quotation_item_id)
      .filter(Boolean);

    // ✅ STEP 12 — Load quotation item details
    const { data: quotationItems, error: quotationItemsErr } = await supabase
      .from("quotation_items")
      .select(
        "quotation_item_id, part_description, part_number, brand_class, price_before_vat, total_price_before_vat, main_brand, customer_id, cost_id",
      )
      .in("quotation_item_id", quotationItemIds.length ? quotationItemIds : [-1]);

    if (quotationItemsErr) throw quotationItemsErr;

    // ✅ STEP 13 — Load vendor cost data
    const costIds = (quotationItems ?? [])
      .map((i) => i.cost_id)
      .filter(Boolean);

    const { data: vendorItems, error: vendorItemsErr } = await supabase
      .from("quotation_vendor_items")
      .select("cost_id, cost, vendor_id, best_cost")
      .in("cost_id", costIds.length ? costIds : [-1]);

    if (vendorItemsErr) throw vendorItemsErr;

    const vendorIds = (vendorItems ?? [])
      .map((v) => v.vendor_id)
      .filter(Boolean);

    const { data: vendors, error: vendorsErr } = await supabase
      .from("vendors")
      .select("vendor_id, vendor_name")
      .in("vendor_id", vendorIds.length ? vendorIds : [-1]);

    if (vendorsErr) throw vendorsErr;

    // ✅ STEP 14 — Load branch/customer Zoho mapping
    const customerId = (quotationItems ?? []).find((q) => q.customer_id)?.customer_id ?? null;

    const { data: branchRow, error: branchErr } = await supabase
      .from("client_branches")
      .select("customer_id, branch_name, zoho_id, list_data_id")
      .eq("customer_id", customerId ?? -1)
      .maybeSingle();

    if (branchErr || !branchRow?.zoho_id) {
      throw new Error("Missing Zoho customer mapping for branch");
    }

    // ✅ STEP 15 — Load customer branch emails
    const { data: branchUsers } = await supabase
      .from("user_data")
      .select("email")
      .eq("user_branch", customerId ?? -1);

    const toEmails = uniqueStrings((branchUsers ?? []).map((u) => u.email));

    // ✅ STEP 16 — Load account manager CC emails
    const { data: managerBranchRows } = await supabase
      .from("account_manager_branches")
      .select("main_account_manager, first_substitute, second_substitute, fallback_account_manager")
      .eq("customer_id", customerId ?? -1);

    const managerIds = uniqueStrings(
      (managerBranchRows ?? []).flatMap((row) => [
        row.main_account_manager,
        row.first_substitute,
        row.second_substitute,
        row.fallback_account_manager,
      ]),
    );

    const { data: managerUsers } = await supabase
      .from("user_data")
      .select("email")
      .in("user_id", managerIds.length ? managerIds : ["00000000-0000-0000-0000-000000000000"]);

    const ccEmails = uniqueStrings((managerUsers ?? []).map((u) => u.email));

    // ✅ STEP 17 — Add special CC for selected clients
    const { data: clientListData } = await supabase
      .from("list_data")
      .select("list_data_id, list_data")
      .eq("list_data_id", branchRow.list_data_id ?? -1)
      .maybeSingle();

    const clientName = String(clientListData?.list_data ?? "").trim().toLowerCase();

    if (clientName && SPECIAL_CC_CLIENTS.has(clientName)) {
      ccEmails.push(SPECIAL_CC_EMAIL);
    }

    // ✅ STEP 18 — Resolve brand class names
    const brandClassIds = uniqueStrings(
      (confirmedItems ?? []).map((i) => String(i.final_brand_class ?? "")),
    )
      .map((id) => Number(id))
      .filter((id) => Number.isFinite(id));

    const { data: brandClassRows } = await supabase
      .from("list_data")
      .select("list_data_id, list_data")
      .in("list_data_id", brandClassIds.length ? brandClassIds : [-1]);

    const brandClassMap = new Map<number, string>();

    for (const row of brandClassRows ?? []) {
      if (row?.list_data_id) {
        brandClassMap.set(row.list_data_id, String(row.list_data ?? ""));
      }
    }

    // ✅ STEP 19 — Build vendor maps
    const vendorMap = new Map<number, string>();

    for (const vendor of vendors ?? []) {
      if (vendor?.vendor_id) {
        vendorMap.set(vendor.vendor_id, String(vendor.vendor_name ?? ""));
      }
    }

    const vendorByCostId = new Map<number, { cost: number; vendorName: string }>();

    for (const item of vendorItems ?? []) {
      if (!item?.cost_id) continue;

      const existing = vendorByCostId.get(item.cost_id);
      const cost = safeNumber(item.cost);
      const vendorName = vendorMap.get(item.vendor_id ?? -1) ?? "";

      if (!existing) {
        vendorByCostId.set(item.cost_id, { cost, vendorName });
        continue;
      }

      if (item.best_cost || cost < existing.cost) {
        vendorByCostId.set(item.cost_id, { cost, vendorName });
      }
    }

    // ✅ STEP 20 — Map delivery items by confirmed_item_id
    const deliveryItemMap = new Map<number, typeof deliveryItems[number]>();

    for (const item of deliveryItems ?? []) {
      if (item.confirmed_item_id) {
        deliveryItemMap.set(item.confirmed_item_id, item);
      }
    }

    // ✅ STEP 21 — Get Zoho OAuth token
    const token = await getZohoToken();
    console.log("Zoho access token acquired");

    // ✅ STEP 22 — Prepare required Zoho account IDs
    const requiredSalesAccountId = Deno.env.get("ZOHO_SALES_ACCOUNT_ID") ?? "";
    const requiredPurchaseAccountId = Deno.env.get("ZOHO_PURCHASE_ACCOUNT_ID") ?? "";
    const requiredInventoryAccountId = Deno.env.get("ZOHO_INVENTORY_ACCOUNT_ID") ?? "";

    if (!requiredSalesAccountId || !requiredPurchaseAccountId || !requiredInventoryAccountId) {
      throw new Error("Missing required Zoho account env vars");
    }

    const itemsPayload = [] as JsonRecord[];
    const lineItemsPayload = [] as JsonRecord[];

    // ✅ STEP 23 — Check Zoho items, update existing matching items, create missing/mismatched items
    for (const confirmedItem of confirmedItems ?? []) {
      const quotationItem = (quotationItems ?? []).find(
        (q) => q.quotation_item_id === confirmedItem.quotation_item_id,
      );

      if (!quotationItem) continue;

      const deliveryItem = deliveryItemMap.get(confirmedItem.confirmed_item_id);
      const quantity = safeNumber(deliveryItem?.delivered_qty ?? confirmedItem.approved_qty);

      if (quantity <= 0) continue;

      const partNumber = String(confirmedItem.final_part_number ?? quotationItem.part_number ?? "").trim();

      if (!partNumber) {
        console.warn("Skipping item because part number is missing", confirmedItem);
        continue;
      }

      const brandClassName = brandClassMap.get(Number(confirmedItem.final_brand_class)) ?? "";
      const sku = buildSku(partNumber, brandClassName || String(quotationItem.brand_class ?? ""));
      const sellingPrice = safeNumber(quotationItem.price_before_vat);
      const vendorData = vendorByCostId.get(quotationItem.cost_id ?? -1);
      const purchaseRate = safeNumber(vendorData?.cost ?? 0);
      const itemDescription = String(quotationItem.part_description ?? "");
      const today = new Date().toISOString().slice(0, 10);

      const baseItemPayload: JsonRecord = {
        name: partNumber || itemDescription,
        name_sec_lang: partNumber || itemDescription,
        rate: sellingPrice,
        purchase_rate: purchaseRate,
        purchase_account_id: requiredPurchaseAccountId,
        account_id: requiredSalesAccountId,
        sales_account_id: requiredSalesAccountId,
        inventory_account_id: requiredInventoryAccountId,
        description: itemDescription,
        purchase_description: itemDescription,
        opening_stock: quantity,
        opening_stock_date: today,
        is_returnable: false,
        sku,
        item_type: "inventory",
        status: "active",
        is_taxable: true,
        tax_name: "Standard Rate",
        tax_percentage: 15,
        unit: "pcs",
        product_type: "goods",
        custom_fields: [
          { api_name: "cf_date", value: today },
          { api_name: "cf_vendor", value: vendorData?.vendorName ?? "" },
          { api_name: "cf_brand_class", value: brandClassName || String(quotationItem.brand_class ?? "") },
          { api_name: "cf_order_number", value: orderNumber },
        ],
      };

      let zohoItem: ZohoItem | null = null;

      // ✅ STEP 23.1 — Search Zoho item by SKU
      const searchRes = await zohoRequest(
        token,
        `/items?search_text=${encodeURIComponent(sku)}`,
        { method: "GET" },
      );

      const matchedItem = (searchRes?.items ?? []).find((it: ZohoItem) =>
        String(it.sku ?? "").trim().toLowerCase() === sku.trim().toLowerCase()
      );

      if (matchedItem?.item_id) {
        const itemDetailsRes = await zohoRequest(token, `/items/${matchedItem.item_id}`, {
          method: "GET",
        });

        zohoItem = itemDetailsRes?.item ?? matchedItem;
      }

      // ✅ STEP 23.2 — Check if existing item has required accounts
      const accountIdsMatch =
        zohoItem &&
        String(zohoItem.sales_account_id ?? zohoItem.account_id ?? "") === requiredSalesAccountId &&
        String(zohoItem.purchase_account_id ?? "") === requiredPurchaseAccountId &&
        String(zohoItem.inventory_account_id ?? "") === requiredInventoryAccountId;

      // ✅ STEP 23.3 — If exists with same accounts, update fields
      if (zohoItem?.item_id && accountIdsMatch) {
        const updatePayload: JsonRecord = {
          name_sec_lang: partNumber || itemDescription,
          rate: sellingPrice,
          purchase_rate: purchaseRate,
          description: itemDescription,
          purchase_description: itemDescription,
          custom_fields: [
            { api_name: "cf_date", value: today },
            { api_name: "cf_vendor", value: vendorData?.vendorName ?? "" },
            { api_name: "cf_brand_class", value: brandClassName || String(quotationItem.brand_class ?? "") },
            { api_name: "cf_order_number", value: orderNumber },
          ],
        };

        const updateRes = await zohoRequest(token, `/items/${zohoItem.item_id}`, {
          method: "PUT",
          body: JSON.stringify(updatePayload),
        });

        zohoItem = updateRes?.item ?? zohoItem;
      }

      // ✅ STEP 23.4 — If missing or account mismatch, create new item
      else {
        const finalSku =
          zohoItem?.item_id && !accountIdsMatch
            ? `${sku}-${orderNumber}`
            : sku;

        const createPayload: JsonRecord = {
          ...baseItemPayload,
          sku: finalSku,
        };

        const createRes = await zohoRequest(token, `/items`, {
          method: "POST",
          body: JSON.stringify(createPayload),
        });

        zohoItem = createRes?.item;
      }

      if (!zohoItem?.item_id) {
        throw new Error(`Zoho item not found/created for SKU ${sku}`);
      }

      // ✅ STEP 23.5 — Collect final item info for invoice
      itemsPayload.push({
        confirmed_item_id: confirmedItem.confirmed_item_id,
        delivery_item_id: deliveryItem?.delivery_item_id,
        quantity,
        item_id: zohoItem.item_id,
        sku: zohoItem.sku ?? sku,
      });

      lineItemsPayload.push({
        item_id: zohoItem.item_id,
        name: partNumber,
        rate: sellingPrice,
        quantity,
        description: itemDescription,
        tax_id: Deno.env.get("ZOHO_TAX_ID"),
      });
    }

    if (!lineItemsPayload.length) {
      throw new Error("No delivered items available to invoice");
    }

    // ✅ STEP 24 — Build invoice payload
    const shippingCharge = Math.max(
      ...((deliveries ?? []).map((d) => safeNumber(d.shipping_price)) || [0]),
    );

    const invoicePayload: JsonRecord = {
      customer_id: branchRow.zoho_id,
      date: new Date().toISOString().slice(0, 10),
      due_date: new Date().toISOString().slice(0, 10),
      location_id: Deno.env.get("ZOHO_LOCATION_ID"),
      notes: "Thanks for your business.",
      terms: "",
      is_inclusive_tax: false,
      discount: 0,
      discount_type: "entity_level",
      shipping_charge: shippingCharge || 0,
      adjustment: 0,
      adjustment_description: "Adjustment",
      reference_number: orderNumber,
      line_items: lineItemsPayload,
    };

    // ✅ STEP 25 — Create invoice in Zoho
    console.log("Creating Zoho invoice");

    const invoiceRes = await zohoRequest(token, `/invoices`, {
      method: "POST",
      body: JSON.stringify(invoicePayload),
    });

    const invoice = invoiceRes?.invoice as InvoiceResult;

    if (!invoice?.invoice_id) {
      throw new Error("Zoho invoice creation failed");
    }

    console.log(`Zoho invoice created: ${invoice.invoice_id}`);

    const createdInvoiceInfo = {
      invoice_id: invoice.invoice_id,
      invoice_number: invoice.invoice_number ?? null,
      invoice_url: invoice.invoice_url ?? null,
    };

    // ✅ STEP 26 — Save invoice immediately after Zoho creation
    let localInvoiceId: number | null = null;

    try {
      const { data: invoiceInsert, error: invoiceInsertErr } = await supabase
        .from("invoices")
        .insert({
          confirmed_order_id: confirmedOrderId,
          invoice_number: invoice.invoice_number ?? null,
          invoice_url: invoice.invoice_url ?? null,
          zoho_status: "created",
          notes: JSON.stringify({ zoho_invoice_id: invoice.invoice_id }),
        })
        .select("invoice_id")
        .maybeSingle();

      if (invoiceInsertErr) throw invoiceInsertErr;

      localInvoiceId = invoiceInsert?.invoice_id ?? null;

      if (!localInvoiceId) {
        throw new Error("Invoice created in Zoho but local invoice_id was not returned");
      }

      const invoiceItemRows = (itemsPayload ?? []).map((item) => ({
        invoice_id: localInvoiceId,
        confirmed_item_id: item.confirmed_item_id,
        invoiced_qty: item.quantity,
      }));

      if (invoiceItemRows.length) {
        const { error: invoiceItemsErr } = await supabase
          .from("invoice_items")
          .insert(invoiceItemRows);

        if (invoiceItemsErr) throw invoiceItemsErr;
      }

      const deliveryItemIdsToUpdate = (itemsPayload ?? [])
        .map((item) => item.delivery_item_id)
        .filter(Boolean);

      if (deliveryItemIdsToUpdate.length) {
        const { error: deliveryUpdateErr } = await supabase
          .from("delivery_items")
          .update({ invoice_id: localInvoiceId })
          .in("delivery_item_id", deliveryItemIdsToUpdate);

        if (deliveryUpdateErr) throw deliveryUpdateErr;
      }
    } catch (err) {
      console.error("Supabase invoice save failed", err);

      return new Response(
        JSON.stringify({
          status: true,
          message: "Zoho invoice created but database save failed",
          ...createdInvoiceInfo,
          approval_failed: null,
          email_failed: true,
          warning: String(err),
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // ✅ STEP 27 — Approve invoice using the correct Zoho approval endpoint
    let approvalFailed = false;
    let emailFailed = false;

    try {
      await zohoRequest(token, `/invoices/${invoice.invoice_id}/approve`, {
        method: "POST",
        body: JSON.stringify({}),
      });

      await supabase
        .from("invoices")
        .update({ zoho_status: "approved" })
        .eq("invoice_id", localInvoiceId);

      console.log(`Zoho invoice approved: ${invoice.invoice_id}`);
    } catch (err) {
      approvalFailed = true;
      emailFailed = true;

      await supabase
        .from("invoices")
        .update({
          zoho_status: "approval_failed",
          notes: JSON.stringify({
            zoho_invoice_id: invoice.invoice_id,
            approval_error: String(err),
          }),
        })
        .eq("invoice_id", localInvoiceId);

      return new Response(
        JSON.stringify({
          status: true,
          message: "Invoice was created and saved, but invoice approval failed. Email was not sent.",
          ...createdInvoiceInfo,
          local_invoice_id: localInvoiceId,
          approval_failed: true,
          email_failed: true,
          warning: String(err),
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // ✅ STEP 28 — Send invoice email only after successful approval
    if (toEmails.length) {
      try {
        const emailSubject = `Invoice ${invoice.invoice_number} Issued for Order number ${orderNumber}`;

        const emailBody = `
         <p>Dear Partner,<br>
         Thank you for signing and confirming the receipt of order number <b>${orderNumber}</b>.<br>
         Invoice <b>${invoice.invoice_number}</b> has been successfully issued for your order.<br>
         Please find your Invoice attached.</p>
         <p>Wishing you a quick & successful fix.<br>Qparts Finance Team</p>
         `;
        await zohoRequest(token, `/invoices/${invoice.invoice_id}/email`, {
          method: "POST",
          body: JSON.stringify({
            to_mail_ids: toEmails,
            cc_mail_ids: ccEmails,
            subject: emailSubject,
            body: emailBody,
            send_from_org_email_id: true,
          }),
        });

        console.log(`Zoho invoice email sent: ${invoice.invoice_id}`);
      } catch (err) {
        emailFailed = true;
        console.error("Zoho invoice email failed", err);
      }
    } else {
      emailFailed = true;
      console.warn("Invoice email skipped because no recipient emails were found");
    }

    // ✅ STEP 29 — Update delivery note and confirmed item statuses only after approval
    try {
      await supabase
        .from("delivery_notes")
        .update({
          invoice_number: invoice.invoice_number ?? null,
          status: "Invoice Issued",
        })
        .eq("order_number", orderNumber);

      const { data: statusRow } = await supabase
        .from("list_data")
        .select("list_data_id")
        .ilike("list_data", "invoice issued")
        .maybeSingle();

      if (statusRow?.list_data_id) {
        await supabase
          .from("confirmed_items")
          .update({ item_status: statusRow.list_data_id })
          .in("confirmed_item_id", confirmedItemIdsFromDelivery);
      }
    } catch (err) {
      console.error("Status update failed", err);

      return new Response(
        JSON.stringify({
          status: true,
          message: "Invoice was created, saved, and approved, but status update failed",
          ...createdInvoiceInfo,
          local_invoice_id: localInvoiceId,
          approval_failed: false,
          email_failed: emailFailed,
          warning: String(err),
        }),
        {
          status: 200,
          headers: { ...corsHeaders, "Content-Type": "application/json" },
        },
      );
    }

    // ✅ STEP 30 — Return invoice info for frontend preview
    return new Response(
      JSON.stringify({
        status: true,
        message: emailFailed
          ? "Invoice issued and approved, but email failed or was skipped"
          : "Invoice issued, approved, emailed, and saved",
        invoice_id: invoice.invoice_id,
        local_invoice_id: localInvoiceId,
        invoice_number: invoice.invoice_number ?? null,
        invoice_url: invoice.invoice_url ?? null,
        approval_failed: false,
        email_failed: emailFailed,
      }),
      {
        status: 200,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  } catch (err) {
    // ✅ STEP 31 — Return clear error response
    console.error("generate_sales_invoice error", err);

    return new Response(
      JSON.stringify({
        status: false,
        message: err instanceof Error ? err.message : String(err),
      }),
      {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      },
    );
  }
});