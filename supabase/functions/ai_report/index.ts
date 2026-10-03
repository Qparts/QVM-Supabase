// ai_report — composes a management report from a prompt.
//
// The signed-in internal user asks for a report; Claude reads the data through the report tools
// (every one scoped in the database to the user's company and branch scope — the model holds no
// company parameter) and composes a recipe; the recipe is saved through save_ai_report and run
// at once. Refreshing a saved report never comes here. Modes:
//   create   { prompt }                      → a new report
//   refine   { prompt, report_id }           → the report's recipe, changed as asked
//   insights { report_id }                   → the insights rewritten over the report's fresh data
//
// Secrets: ANTHROPIC_API_KEY (required), AI_REPORT_MODEL (optional, default claude-opus-5-5).

import Anthropic from "npm:@anthropic-ai/sdk";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { COMPOSE_TOOL, SYSTEM_PROMPT, reportToolDefinitions, summarizeForModel, validateSpec } from "../_shared/aiReportTools.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const MODEL = Deno.env.get("AI_REPORT_MODEL") || "claude-opus-5-5";
const MAX_ITERATIONS = 10;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ status: "fail", message: "POST only" }, 405);

  const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!apiKey) return json({ status: "fail", message: "The AI report service is not configured (ANTHROPIC_API_KEY)" }, 503);

  // Who is asking: the user's own JWT, used for every database call so the company scope and
  // the audit rows are theirs.
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) return json({ status: "fail", message: "Not authorized" }, 401);
  const db = createClient(SUPABASE_URL, ANON_KEY, { global: { headers: { Authorization: `Bearer ${jwt}` } } });
  const { data: userRes, error: userErr } = await db.auth.getUser(jwt);
  if (userErr || !userRes?.user) return json({ status: "fail", message: "Not authorized" }, 401);

  let body: { prompt?: string; report_id?: number | null; mode?: string } = {};
  try { body = await req.json(); } catch { return json({ status: "fail", message: "Malformed body" }, 400); }
  const mode = body.mode === "refine" || body.mode === "insights" ? body.mode : "create";
  const prompt = String(body.prompt ?? "").trim();
  const reportId = body.report_id != null ? Number(body.report_id) : null;
  if (mode !== "insights" && (prompt.length < 4 || prompt.length > 2000)) return json({ status: "fail", message: "Describe the report in a few words (up to 2000 characters)" }, 400);
  if (mode !== "create" && !reportId) return json({ status: "fail", message: "report_id is required" }, 400);

  // Internal users only, within their rate: the database decides both.
  const { data: rate, error: rateErr } = await db.rpc("ai_report_rate_check");
  if (rateErr) return json({ status: "fail", message: rateErr.message }, rateErr.message.includes("internal users") ? 403 : 400);
  if (!rate?.allowed) return json({ status: "fail", message: "Too many reports in a short time — try again in a minute" }, 429);

  // The report being refined, when there is one.
  let existing: Record<string, unknown> | null = null;
  if (reportId) {
    const { data, error } = await db.rpc("get_ai_report", { p_report_id: reportId });
    if (error || !data) return json({ status: "fail", message: error?.message || "Unknown report" }, 404);
    existing = data as Record<string, unknown>;
  }

  const anthropic = new Anthropic({ apiKey });
  const tools = [...reportToolDefinitions(), COMPOSE_TOOL] as unknown as Anthropic.Beta.BetaToolUnion[];

  // What the model is asked, per mode.
  let userText: string;
  if (mode === "create") {
    userText = prompt;
  } else if (mode === "refine") {
    userText = `Here is an existing report, as its recipe (JSON): ${JSON.stringify({ title: existing!.title, sections: existing!.spec })}\n\nChange it as follows, keeping what is not mentioned, then call compose_report with the full updated report: ${prompt}`;
  } else {
    // Insights only: the recipe stays; the model sees the fresh data and rewrites the sentences.
    userText = `Here is a report's recipe and the data each section produced just now (JSON): ${JSON.stringify({ title: existing!.title, sections: existing!.spec, results: (existing!.last_result as unknown[]).map((r) => JSON.parse(summarizeForModel(r as Record<string, unknown>, 40))) })}\n\nRewrite the insight of every section from these numbers, in the same language as the titles, and call compose_report with the same title, tools, params and visuals — only the insights change. Do not call any other tool.`;
  }
  const messages: Anthropic.Beta.BetaMessageParam[] = [{ role: "user", content: userText }];

  let inputTokens = 0, outputTokens = 0;
  const toolCalls: Array<{ tool: string; params: unknown; rows: number }> = [];

  try {
    for (let i = 0; i < MAX_ITERATIONS; i++) {
      const response = await anthropic.beta.messages.create({
        model: MODEL,
        max_tokens: 16000,
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
        system: SYSTEM_PROMPT,
        tools,
        tool_choice: { type: "auto" },
        messages,
      } as unknown as Anthropic.Beta.MessageCreateParamsNonStreaming);
      inputTokens += response.usage.input_tokens;
      outputTokens += response.usage.output_tokens;

      if (response.stop_reason === "refusal") {
        return json({ status: "fail", message: "The model declined this request. Please rephrase it." }, 422);
      }
      if (response.stop_reason === "max_tokens") {
        return json({ status: "fail", message: "The report was too long to compose in one go — ask for fewer sections." }, 422);
      }
      if (response.stop_reason === "pause_turn") {
        messages.push({ role: "assistant", content: response.content });
        continue;
      }

      const toolUses = response.content.filter((b): b is Anthropic.Beta.BetaToolUseBlock => b.type === "tool_use");
      if (toolUses.length === 0) {
        const text = response.content.filter((b) => b.type === "text").map((b) => (b as Anthropic.Beta.BetaTextBlock).text).join("\n").trim();
        return json({ status: "fail", message: text || "The model did not compose a report. Try describing it differently." }, 422);
      }

      // The finished report ends the loop: validate, save (which runs it), log, answer.
      const compose = toolUses.find((t) => t.name === "compose_report");
      if (compose) {
        const spec = validateSpec(compose.input);
        const { data: report, error: saveErr } = await db.rpc("save_ai_report", {
          p_report_id: mode === "create" ? null : reportId,
          p_title: spec.title,
          p_prompt: mode === "insights" ? (existing!.prompt as string) : prompt,
          p_spec: spec.sections,
          p_model: MODEL,
          p_source: "web",
        });
        if (saveErr) return json({ status: "fail", message: saveErr.message }, 400);
        await db.rpc("log_ai_report_generation", {
          p_report_id: (report as Record<string, unknown>).report_id, p_action: mode, p_prompt: prompt || null, p_model: MODEL,
          p_input_tokens: inputTokens, p_output_tokens: outputTokens, p_client: "web",
        });
        return json({ status: "success", report, usage: { input_tokens: inputTokens, output_tokens: outputTokens, tool_calls: toolCalls } });
      }

      // Report tools: run each in the database as the user, hand the rows back together.
      messages.push({ role: "assistant", content: response.content });
      const results: Anthropic.Beta.BetaToolResultBlockParam[] = [];
      for (const call of toolUses) {
        const params = (call.input && typeof call.input === "object") ? call.input : {};
        const { data, error } = await db.rpc("ai_report_tool", { p_tool: call.name, p_params: params });
        if (error) {
          results.push({ type: "tool_result", tool_use_id: call.id, content: `Error: ${error.message}`, is_error: true });
          toolCalls.push({ tool: call.name, params, rows: -1 });
        } else {
          results.push({ type: "tool_result", tool_use_id: call.id, content: summarizeForModel(data as Record<string, unknown>) });
          toolCalls.push({ tool: call.name, params, rows: Number((data as Record<string, unknown>).row_count ?? 0) });
        }
      }
      messages.push({ role: "user", content: results });
    }
    return json({ status: "fail", message: "The report took too many steps to compose — ask for something narrower." }, 422);
  } catch (err) {
    if (err instanceof Anthropic.RateLimitError) return json({ status: "fail", message: "The AI service is busy — try again shortly" }, 429);
    if (err instanceof Anthropic.AuthenticationError) return json({ status: "fail", message: "The AI service key is not valid" }, 503);
    if (err instanceof Anthropic.APIError) return json({ status: "fail", message: `AI service error ${err.status}: ${err.message}` }, 502);
    return json({ status: "fail", message: String((err as Error)?.message || err) }, 500);
  }
});
