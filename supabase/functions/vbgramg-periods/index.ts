import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = new Set(["https://enga.in", "https://www.enga.in", "https://enga018.github.io"]);
function headers(req: Request) {
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
  return new Response(JSON.stringify(body), { status, headers: headers(req) });
}
const clean = (v: unknown, max = 120) => typeof v === "string" ? v.trim().slice(0, max) : "";
function monthName(date: string) {
  const [year, month] = date.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, 1)).toLocaleDateString("en-US", { month: "long", year: "numeric", timeZone: "UTC" });
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: headers(req) });
  if (req.method !== "POST") return reply(req, { error: "Method not allowed." }, 405);
  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token || token === authorization) return reply(req, { error: "Sign in required." }, 401);
  const url = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY"), service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return reply(req, { error: "Server configuration is incomplete." }, 500);
  try {
    const auth = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: authData, error: authError } = await auth.auth.getUser(token);
    const user = authData.user;
    if (authError || !user || !user.email_confirmed_at) return reply(req, { error: "A verified account is required." }, 401);
    const email = (user.email || "").trim().toLowerCase();
    const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
    const { data: approved, error: approvalError } = await admin.from("vbgramg_approved_users").select("email,role").eq("email", email).maybeSingle();
    if (approvalError) return reply(req, { error: "Could not verify app access." }, 500);
    if (!approved) return reply(req, { error: "This account has not been approved for VBGRAMG." }, 403);
    let body: Record<string, unknown>;
    try { body = await req.json(); } catch { return reply(req, { error: "Invalid JSON request." }, 400); }
    const action = clean(body.action, 30);
    if (action === "list") {
      const { data, error } = await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,days,status,created_at,updated_at,closed_at").order("period_date", { ascending: false, nullsFirst: false }).order("created_at", { ascending: false });
      if (error) throw error;
      return reply(req, { approved: true, periods: data || [] });
    }
    const id = clean(body.id, 64);
    if (["close", "reopen", "update"].includes(action)) {
      if (!id) return reply(req, { error: "A period ID is required." }, 400);
      const { data: existing, error: readError } = await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,days,status").eq("id", id).maybeSingle();
      if (readError) throw readError;
      if (!existing) return reply(req, { error: "Period not found." }, 404);
      let patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
      if (action === "close") patch = { ...patch, status: "closed", closed_at: new Date().toISOString() };
      if (action === "reopen") patch = { ...patch, status: "open", closed_at: null };
      if (action === "update") {
        const daysRaw = body.days === null || body.days === "" || body.days === undefined ? null : Number(body.days);
        if (daysRaw !== null && (!Number.isInteger(daysRaw) || daysRaw < 1 || daysRaw > 365)) return reply(req, { error: "Days must be a whole number from 1 to 365, or blank." }, 400);
        patch.days = daysRaw;
        if (!existing.period_date) {
          const name = clean(body.periodName, 120);
          if (!name) return reply(req, { error: "Period name is required." }, 400);
          patch.period_name = name;
        } else if (body.periodName && clean(body.periodName, 120) !== existing.period_name) {
          return reply(req, { error: "Monthly contribution period names are fixed to their month and year." }, 400);
        }
      }
      const { data, error } = await admin.from("vbgramg_periods").update(patch).eq("id", id).select("id,period_name,period_date,contribution_month,days,status,created_at,updated_at,closed_at").single();
      if (error) {
        if (error.code === "23505") return reply(req, { error: "A period with that name or month already exists." }, 409);
        throw error;
      }
      return reply(req, { approved: true, period: data });
    }
    if (action === "create") {
      const month = clean(body.contributionMonth, 10);
      const days = body.days === null || body.days === "" || body.days === undefined ? null : Number(body.days);
      if (!/^\d{4}-\d{2}-01$/.test(month) || Number.isNaN(Date.parse(month))) return reply(req, { error: "Choose a valid contribution month. It is required." }, 400);
      if (days !== null && (!Number.isInteger(days) || days < 1 || days > 365)) return reply(req, { error: "Days must be a whole number from 1 to 365, or blank." }, 400);
      const { data: existing, error: existingError } = await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,status").eq("contribution_month", month).order("period_date", { ascending: true });
      if (existingError) throw existingError;
      if ((existing || []).length && body.confirmAdditionalRound !== true) return reply(req, { error: "A period already exists for this contribution month. Confirm creation of another charge round.", confirmation_required: true, existing_periods: existing || [] }, 409);
      const usedDates = new Set((existing || []).map((p: {period_date?: string|null}) => String(p.period_date || "")));
      let periodDate = "";
      const [year, monthNumber] = month.split("-").map(Number);
      for (let day = 1; day <= 31; day++) {
        const candidate = new Date(Date.UTC(year, monthNumber - 1, day)).toISOString().slice(0, 10);
        if (candidate.slice(0, 7) !== month.slice(0, 7)) break;
        if (!usedDates.has(candidate)) { periodDate = candidate; break; }
      }
      if (!periodDate) return reply(req, { error: "No available charge-round date remains in this contribution month." }, 409);
      const roundNo = Number(periodDate.slice(8, 10));
      const baseName = monthName(month);
      const periodName = roundNo === 1 ? baseName : baseName + " (" + roundNo + ")";
      const { data, error } = await admin.from("vbgramg_periods").insert({ period_name: periodName, period_date: periodDate, contribution_month: month, days, status: "open", created_by: user.id }).select("id,period_name,period_date,contribution_month,days,status,created_at,updated_at,closed_at").single();
      if (error) {
        if (error.code === "23505") return reply(req, { error: "Another period was created for this month at the same time. Refresh the list and try again." }, 409);
        throw error;
      }
      return reply(req, { approved: true, period: data }, 201);
    }
    return reply(req, { error: "Unsupported action." }, 400);
  } catch (error) {
    console.error("Period management failed:", error);
    return reply(req, { error: "Could not complete the period operation. Please retry." }, 500);
  }
});