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
  const shortMonth = new Date(Date.UTC(year, month - 1, 1)).toLocaleDateString("en-US", { month: "short", timeZone: "UTC" }).toUpperCase();
  return shortMonth + String(year).slice(-2);
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
      const { data, error } = await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,days,status,created_at,updated_at,closed_at").order("contribution_month", { ascending: false, nullsFirst: false }).order("created_at", { ascending: false });
      if (error) throw error;
      const periodRows = data || [];
      // PostgREST normally caps each response at 1,000 rows. Paginate every
      // usage table so older periods cannot appear unused just because their
      // linked rows fall beyond the first response page.
      const usageTables = [
        "vbgramg_charge_ledger",
        "vbgramg_payment_allocations",
        "vbgramg_contribution_extras",
        "vbgramg_fto_batches",
        "vbgramg_demand_runs"
      ] as const;
      const usageResults = await Promise.all(usageTables.map(async (table) => {
        const ids: string[] = [];
        for (let offset = 0; ; offset += 1000) {
          const { data: rows, error: usageError } = await admin
            .from(table)
            .select("period_id")
            .not("period_id", "is", null)
            .range(offset, offset + 999);
          if (usageError) throw usageError;
          for (const row of rows || []) if (row.period_id) ids.push(String(row.period_id));
          if (!rows || rows.length < 1000) break;
        }
        return ids;
      }));
      const usedIds = new Set<string>(usageResults.flat());
      return reply(req, { approved: true, periods: periodRows.map(period => ({ ...period, used: usedIds.has(String(period.id)) })) });
    }
    if (action === "ensure-base") {
      const month = clean(body.contributionMonth, 10);
      if (!/^\d{4}-\d{2}-01$/.test(month) || Number.isNaN(Date.parse(month)) || new Date(month + "T00:00:00Z").toISOString().slice(0, 10) !== month) {
        return reply(req, { error: "Choose a valid contribution month." }, 400);
      }
      const base = monthName(month);
      const findBase = async () => {
        const { data, error } = await admin.from("vbgramg_periods")
          .select("id,period_name,period_date,contribution_month,days,status,created_at,updated_at,closed_at")
          .eq("contribution_month", month).eq("period_name", base).maybeSingle();
        if (error) throw error;
        return data;
      };
      let period = await findBase();
      if (period) {
        if (period.status !== "open") return reply(req, { error: base + " already exists but is closed. It was not reopened or replaced. Reopen it on the Periods page, or create/select another period explicitly." }, 409);
        return reply(req, { approved: true, period, reused: true });
      }
      const { data: created, error: createError } = await admin.from("vbgramg_periods").insert({
        period_name: base, period_date: month, contribution_month: month, days: null,
        status: "open", created_by: user.id
      }).select("id,period_name,period_date,contribution_month,days,status,created_at,updated_at,closed_at").single();
      if (createError) {
        if (createError.code === "23505") {
          period = await findBase();
          if (period && period.status === "open") return reply(req, { approved: true, period, reused: true });
          if (period && period.status !== "open") return reply(req, { error: base + " already exists but is closed. It was not reopened or replaced." }, 409);
        }
        throw createError;
      }
      return reply(req, { approved: true, period: created, reused: false });
    }
    if (action === "create") {
      const month = clean(body.contributionMonth, 10);
      const days = body.days === null || body.days === "" || body.days === undefined ? null : Number(body.days);
      if (!/^\d{4}-\d{2}-01$/.test(month) || Number.isNaN(Date.parse(month)) || new Date(month + "T00:00:00Z").toISOString().slice(0,10) !== month) return reply(req, { error: "Choose a valid contribution month." }, 400);
      if (days !== null && (!Number.isInteger(days) || days < 1 || days > 365)) return reply(req, { error: "Days must be a whole number from 1 to 365, or blank." }, 400);
      const { data: existing, error: existingError } = await admin.from("vbgramg_periods").select("period_name,period_date").eq("contribution_month", month);
      if (existingError) throw existingError;
      const base = monthName(month);
      let highest = 0;
      for (const row of existing || []) {
        const name = String(row.period_name || "");
        if (name === base) highest = Math.max(highest, 1);
        else if (name.startsWith(base + " (") && name.endsWith(")")) {
          const n = Number(name.slice(base.length + 2, -1));
          if (Number.isInteger(n)) highest = Math.max(highest, n);
        }
      }
      const periodNumber = highest + 1;
      const year = Number(month.slice(0, 4));
      const monthNumber = Number(month.slice(5, 7));
      const daysInMonth = new Date(Date.UTC(year, monthNumber, 0)).getUTCDate();
      if (periodNumber > daysInMonth) return reply(req, { error: "All calendar dates in this charge month have already been assigned to periods." }, 409);
      const periodDate = `${month.slice(0, 7)}-${String(periodNumber).padStart(2, "0")}`;
      const periodName = periodNumber === 1 ? base : `${base} (${periodNumber})`;
      const { data: period, error } = await admin.from("vbgramg_periods").insert({ period_name: periodName, period_date: periodDate, contribution_month: month, days, status: "open", created_by: user.id }).select("id,period_name,period_date,contribution_month,days,status,created_at,updated_at,closed_at").single();
      if (error) { if (error.code === "23505") return reply(req, { error: "That period name already exists. Refresh and try again." }, 409); throw error; }
      return reply(req, { approved: true, period });
    }
    if (action === "delete") {
      const deleteId = clean(body.id, 64);
      if (!deleteId) return reply(req, { error: "A period ID is required." }, 400);
      const { data: existing, error: readError } = await admin.from("vbgramg_periods").select("id,period_name").eq("id", deleteId).maybeSingle();
      if (readError) throw readError;
      if (!existing) return reply(req, { error: "Period not found." }, 404);
      const checks = await Promise.all([
        admin.from("vbgramg_charge_ledger").select("id", { count: "exact", head: true }).eq("period_id", deleteId),
        admin.from("vbgramg_payment_allocations").select("id", { count: "exact", head: true }).eq("period_id", deleteId),
        admin.from("vbgramg_contribution_extras").select("id", { count: "exact", head: true }).eq("period_id", deleteId),
        admin.from("vbgramg_fto_batches").select("id", { count: "exact", head: true }).eq("period_id", deleteId),
        admin.from("vbgramg_demand_runs").select("id", { count: "exact", head: true }).eq("period_id", deleteId)
      ]);
      const failed = checks.find(x => x.error);
      if (failed) throw failed.error;
      if (checks.some(x => (x.count || 0) > 0)) return reply(req, { error: "Cannot delete " + existing.period_name + ": linked charges or saved records exist. Close the period instead." }, 409);
      const { error: deleteError } = await admin.from("vbgramg_periods").delete().eq("id", deleteId);
      if (deleteError) throw deleteError;
      return reply(req, { approved: true, deleted: true, periodName: existing.period_name });
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
        if (body.periodName && clean(body.periodName, 120) !== existing.period_name) {
          return reply(req, { error: "Generated period names cannot be changed. The name identifies its contribution month and charge round." }, 400);
        }
      }
      const { data, error } = await admin.from("vbgramg_periods").update(patch).eq("id", id).select("id,period_name,period_date,contribution_month,days,status,created_at,updated_at,closed_at").single();
      if (error) {
        if (error.code === "23505") return reply(req, { error: "Could not update this period. Refresh and try again." }, 409);
        throw error;
      }
      return reply(req, { approved: true, period: data });
    }
    return reply(req, { error: "Unsupported action." }, 400);
  } catch (error) {
    console.error("Period management failed:", error);
    return reply(req, { error: "Could not complete the period operation. Please retry." }, 500);
  }
});