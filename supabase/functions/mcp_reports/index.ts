// mcp_reports — the QVM reports as an MCP server (Streamable HTTP, stateless).
//
// An internal user connects Claude Desktop, Claude Code or another MCP client to this URL with a
// personal access token made on their QVM profile (or a QVM session JWT). The client's own model
// does the reasoning; this server only exposes tools — the same report tools the website uses,
// plus the saved reports — and runs every one in the database as that user, so the company scope,
// branch scope, row caps and audit rows are exactly the website's. No model runs here and no
// tokens are spent on QVM's account.
//
// Protocol: JSON-RPC 2.0 over POST, MCP 2025-06-18 (stateless: no session id, no SSE stream).
// Methods: initialize, notifications/*, ping, tools/list, tools/call.
// Secrets: SUPABASE_DB_URL (provided by the platform), SUPABASE_SERVICE_ROLE_KEY (token lookup only).

import { Pool } from "https://deno.land/x/postgres@v0.17.0/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { PARAMS_SCHEMA, REPORT_TOOLS, VISUALS } from "../_shared/aiReportTools.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const DB_URL = Deno.env.get("SUPABASE_DB_URL")!;
const PROTOCOL_VERSION = "2025-06-18";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, mcp-protocol-version, mcp-session-id, accept",
  "Access-Control-Allow-Methods": "POST, GET, DELETE, OPTIONS",
};
const jsonResponse = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(body === null ? null : JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json", ...extra } });

type RpcRequest = { jsonrpc: "2.0"; id?: number | string | null; method: string; params?: Record<string, unknown> };
const rpcError = (id: number | string | null | undefined, code: number, message: string, data?: unknown) =>
  ({ jsonrpc: "2.0", id: id ?? null, error: { code, message, ...(data !== undefined ? { data } : {}) } });
const rpcResult = (id: number | string | null | undefined, result: unknown) => ({ jsonrpc: "2.0", id: id ?? null, result });

// ───────────── who is calling ─────────────

async function resolveUser(authHeader: string | null): Promise<string | null> {
  const token = (authHeader || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return null;
  const admin = createClient(SUPABASE_URL, SERVICE_KEY);
  if (token.startsWith("qvm_")) {
    // A personal access token: looked up by hash; the lookup is service-role only.
    const { data, error } = await admin.rpc("resolve_api_token", { p_token: token });
    if (error || !data) return null;
    return String(data);
  }
  // Otherwise a QVM session JWT.
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) return null;
  return data.user.id;
}

// ───────────── running a database function as the user ─────────────

const pool = new Pool(DB_URL, 2, true);

async function asUser<T>(userId: string, sql: string, args: unknown[]): Promise<T> {
  const conn = await pool.connect();
  try {
    await conn.queryArray("BEGIN");
    // The claims auth.uid() reads, for this transaction only; every function then scopes to this user.
    await conn.queryArray("SELECT set_config('request.jwt.claims', $1, true), set_config('qvm.ai_client', 'mcp', true)", [
      JSON.stringify({ sub: userId, role: "authenticated" }),
    ]);
    const r = await conn.queryObject<{ v: T }>(sql, args);
    await conn.queryArray("COMMIT");
    return r.rows[0]?.v as T;
  } catch (e) {
    try { await conn.queryArray("ROLLBACK"); } catch { /* already gone */ }
    throw e;
  } finally {
    conn.release();
  }
}

// ───────────── the tools ─────────────

const SPEC_SCHEMA = {
  type: "object",
  properties: {
    title: { type: "string" },
    sections: {
      type: "array", minItems: 1, maxItems: 8,
      items: {
        type: "object",
        properties: {
          tool: { type: "string", enum: REPORT_TOOLS.map((t) => t.name) },
          params: PARAMS_SCHEMA,
          visual: { type: "string", enum: [...VISUALS] },
          title: { type: "string" },
          insight: { type: ["string", "null"] },
        },
        required: ["tool", "params", "visual", "title"],
      },
    },
  },
  required: ["title", "sections"],
};

function toolList() {
  const reportTools = REPORT_TOOLS.map((t) => ({
    name: t.name,
    description: `${t.description} Returns rows with columns: ${t.columns.join(", ")}. Data is limited to your own company and branches.`,
    inputSchema: { type: "object", properties: PARAMS_SCHEMA.properties, required: ["range"] },
  }));
  return [
    ...reportTools,
    { name: "list_reports", description: "The saved reports of your company: id, title, prompt, when last run.", inputSchema: { type: "object", properties: {} } },
    { name: "get_report", description: "One saved report with its recipe and the data it last produced.", inputSchema: { type: "object", properties: { report_id: { type: "integer" } }, required: ["report_id"] } },
    { name: "run_report", description: "Re-run a saved report against live data and return the fresh data. No model is involved.", inputSchema: { type: "object", properties: { report_id: { type: "integer" } }, required: ["report_id"] } },
    { name: "save_report", description: "Save a report recipe (title + sections of tool/params/visual/title/insight) so it appears on the QVM Management Overview and can be refreshed there. Pass report_id to overwrite one of yours.", inputSchema: { type: "object", properties: { report_id: { type: ["integer", "null"] }, prompt: { type: ["string", "null"] }, report: SPEC_SCHEMA }, required: ["report"] } },
  ];
}

async function callTool(userId: string, name: string, args: Record<string, unknown>) {
  if (REPORT_TOOLS.some((t) => t.name === name)) {
    return await asUser(userId, "SELECT qvm_new_apps.ai_report_tool($1, $2::jsonb) AS v", [name, JSON.stringify(args ?? {})]);
  }
  switch (name) {
    case "list_reports":
      return await asUser(userId, "SELECT (SELECT jsonb_agg(e - 'last_result' - 'spec') FROM jsonb_array_elements(qvm_new_apps.list_ai_reports()) e) AS v", []);
    case "get_report":
      return await asUser(userId, "SELECT qvm_new_apps.get_ai_report($1) AS v", [Number(args.report_id)]);
    case "run_report":
      return await asUser(userId, "SELECT qvm_new_apps.run_ai_report($1) AS v", [Number(args.report_id)]);
    case "save_report": {
      const report = (args.report ?? {}) as Record<string, unknown>;
      return await asUser(userId, "SELECT qvm_new_apps.save_ai_report($1, $2, $3, $4::jsonb, $5, 'mcp') AS v", [
        args.report_id == null ? null : Number(args.report_id), String(report.title ?? ""), args.prompt == null ? null : String(args.prompt),
        JSON.stringify(report.sections ?? []), "mcp-client",
      ]);
    }
    default:
      throw new Error(`Unknown tool ${name}`);
  }
}

// ───────────── the protocol ─────────────

async function handle(req: RpcRequest, userId: string) {
  const id = req.id;
  const isNotification = id === undefined || id === null;
  switch (req.method) {
    case "initialize": {
      const requested = String(req.params?.protocolVersion ?? PROTOCOL_VERSION);
      return rpcResult(id, {
        protocolVersion: ["2025-06-18", "2025-03-26", "2024-11-05"].includes(requested) ? requested : PROTOCOL_VERSION,
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "qvm-reports", version: "1.0.0" },
        instructions: "QVM management reports for your own company. Use the report tools to read data, save_report to keep a report on the QVM Management Overview, run_report to refresh a saved one.",
      });
    }
    case "ping":
      return rpcResult(id, {});
    case "tools/list":
      return rpcResult(id, { tools: toolList() });
    case "tools/call": {
      const name = String(req.params?.name ?? "");
      const args = (req.params?.arguments ?? {}) as Record<string, unknown>;
      try {
        const result = await callTool(userId, name, args);
        return rpcResult(id, { content: [{ type: "text", text: JSON.stringify(result) }], structuredContent: result && typeof result === "object" && !Array.isArray(result) ? result : { result }, isError: false });
      } catch (e) {
        // A tool failure is a tool result, not a protocol error — the client's model can recover.
        return rpcResult(id, { content: [{ type: "text", text: `Error: ${(e as Error).message}` }], isError: true });
      }
    }
    default:
      if (isNotification || req.method.startsWith("notifications/")) return null;
      return rpcError(id, -32601, `Method not found: ${req.method}`);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method === "GET") {
    // No server-initiated stream in this stateless server; a browser gets a short description.
    return jsonResponse({ name: "qvm-reports", transport: "streamable-http", note: "POST JSON-RPC here with Authorization: Bearer <QVM personal access token>." });
  }
  if (req.method === "DELETE") return new Response(null, { status: 200, headers: corsHeaders });
  if (req.method !== "POST") return jsonResponse({ error: "POST only" }, 405);

  const userId = await resolveUser(req.headers.get("Authorization"));
  if (!userId) {
    return jsonResponse(rpcError(null, -32001, "Unauthorized: send a QVM personal access token as a Bearer token"), 401, { "WWW-Authenticate": 'Bearer realm="qvm-reports"' });
  }

  let payload: RpcRequest | RpcRequest[];
  try { payload = await req.json(); } catch { return jsonResponse(rpcError(null, -32700, "Parse error"), 400); }
  const requests = Array.isArray(payload) ? payload : [payload];
  const responses = (await Promise.all(requests.map((r) => handle(r, userId)))).filter((r) => r !== null);
  if (responses.length === 0) return new Response(null, { status: 202, headers: corsHeaders });
  return jsonResponse(Array.isArray(payload) ? responses : responses[0], 200, { "MCP-Protocol-Version": PROTOCOL_VERSION });
});
