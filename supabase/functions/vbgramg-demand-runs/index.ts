import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = new Set(["https://enga.in", "https://www.enga.in", "https://enga018.github.io"]);
function cors(req: Request) {
  const origin = req.headers.get("Origin") || "";
  return {
    "Access-Control-Allow-Origin": allowedOrigins.has(origin) ? origin : "https://enga.in",
    "Vary": "Origin",
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Content-Type": "application/json",
  };
}
function reply(req: Request, body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: cors(req) });
}
const textValue = (value: unknown, max = 300) =>
  typeof value === "string" ? value.trim().slice(0, max) : "";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors(req) });
  if (req.method !== "POST") return reply(req, { error: "Method not allowed" }, 405);
  const header = req.headers.get("Authorization") || "";
  const token = header.replace(/^Bearer\s+/i, "");
  if (!token || token === header) return reply(req, { error: "Sign in required." }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply(req, { error: "Server configuration is incomplete." }, 500);

  try {
    const auth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: authData, error: authError } = await auth.auth.getUser(token);
    const user = authData.user;
    if (authError || !user || !user.email_confirmed_at) return reply(req, { error: "A verified account is required." }, 401);

    const email = (user.email || "").trim().toLowerCase();
    const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: approved, error: approvalError } = await admin
      .from("vbgramg_approved_users").select("email,role").eq("email", email).maybeSingle();
    if (approvalError) {
      console.error("Approved-user lookup failed:", approvalError);
      return reply(req, { error: "Could not verify app access." }, 500);
    }
    if (!approved) return reply(req, { error: "This account has not been approved for VBGRAMG." }, 403);

    let body: Record<string, unknown>;
    try { body = await req.json(); }
    catch { return reply(req, { error: "Invalid JSON request." }, 400); }
    if (body.action !== "save") return reply(req, { error: "Unsupported action." }, 400);

    let periodId = textValue(body.periodId, 64);
    const periodName = textValue(body.periodName, 120);
    const days = Number(body.days);
    if (!periodName || !Number.isInteger(days) || days < 1 || days > 365) {
      return reply(req, { error: "Choose a period and enter a valid number of days." }, 400);
    }
    let period: { id: string; period_name: string; status: string } | null = null;
    if (periodId) {
      const { data, error } = await admin.from("vbgramg_periods").select("id,period_name,status").eq("id", periodId).maybeSingle();
      if (error) throw error;
      period = data;
    } else {
      const { data, error } = await admin.from("vbgramg_periods").select("id,period_name,status").eq("period_name", periodName).eq("status", "open").maybeSingle();
      if (error) throw error;
      period = data;
      if (!period) return reply(req, { error: "Create a period in Period Management with a contribution month before starting Work Demand." }, 400);
      periodId = period.id;
    }
    if (!period || period.status !== "open" || period.period_name !== periodName) {
      return reply(req, { error: "That period is no longer open. Refresh periods and try again." }, 409);
    }
    if (!Array.isArray(body.workDemand) || !Array.isArray(body.unwillingToWork) ||
        body.workDemand.length > 5000 || body.unwillingToWork.length > 5000) {
      return reply(req, { error: "The applicant lists are invalid or too large." }, 400);
    }

    const workDemand = body.workDemand.map((raw: unknown) => {
      const item = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
      const jobCard = textValue(item.jobCard, 120);
      if (!jobCard) throw new Error("Each Work Demand entry must have a Job Card Number.");
      return { jobCard, name: textValue(item.name, 200), number: textValue(item.number, 80), household: textValue(item.household, 200) };
    });
    const unwillingToWork = body.unwillingToWork.map((raw: unknown) => {
      const item = (raw && typeof raw === "object" ? raw : {}) as Record<string, unknown>;
      const jobCard = textValue(item.jobCard, 120);
      if (!jobCard) throw new Error("Each Unwilling to Work entry must have a Job Card Number.");
      return { jobCard, household: textValue(item.household, 200) };
    });

    const { data: saved, error: saveError } = await admin.from("vbgramg_demand_runs").insert({
      period_id: periodId, period_name: period.period_name, days, village_scope: "New Serchhip North",
      work_demand: workDemand, unwilling_to_work: unwillingToWork,
      work_demand_count: workDemand.length, unwilling_count: unwillingToWork.length,
      created_by: user.id, created_by_email: email,
    }).select("id,created_at").single();
    if (saveError || !saved) {
      console.error("Demand snapshot save failed:", saveError);
      return reply(req, { error: "Could not save the demand snapshot. Please try again." }, 500);
    }
    return reply(req, { saved: true, id: saved.id, createdAt: saved.created_at,
      workDemandCount: workDemand.length, unwillingCount: unwillingToWork.length });
  } catch (error) {
    const message = error instanceof Error ? error.message : "Invalid demand snapshot.";
    return reply(req, { error: message }, 400);
  }
});
