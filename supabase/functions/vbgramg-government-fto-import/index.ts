import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://enga018.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function reply(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed." }, 405);

  const header = req.headers.get("Authorization") || "";
  const token = header.replace(/^Bearer\s+/i, "");
  if (!token || token === header) return reply({ error: "Sign in required." }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete." }, 500);

  const auth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await auth.auth.getUser(token);
  if (authError || !authData.user || !authData.user.email_confirmed_at) {
    return reply({ error: "A verified account is required." }, 401);
  }

  const email = (authData.user.email || "").trim().toLowerCase();
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approved, error: approvedError } = await admin
    .from("vbgramg_approved_users").select("email,role").eq("email", email).maybeSingle();
  if (approvedError) {
    console.error("Administrator lookup failed:", approvedError);
    return reply({ error: "Could not verify administrator access." }, 500);
  }
  if (!approved || approved.role !== "admin") return reply({ error: "Only an approved VBGRAMG administrator can import Government FTO batches." }, 403);

  let payload: Record<string, unknown>;
  try {
    const raw = await req.text();
    if (raw.length > 8_000_000) return reply({ error: "The import preview is too large." }, 413);
    payload = JSON.parse(raw);
  } catch {
    return reply({ error: "The import request is not valid JSON." }, 400);
  }

  if (!payload || !payload.previewMeta || !Array.isArray(payload.ftos)) {
    return reply({ error: "The validated Government FTO preview payload is incomplete." }, 400);
  }

  const { data, error } = await admin.rpc("vbgramg_import_rejected_fto_batches", {
    p_payload: payload,
    p_actor: authData.user.id,
  });
  if (error) {
    console.error("Government FTO import rejected:", error);
    const status = /already exists|duplicate|changed|does not match|expected|invalid|not open|active MIS/i.test(error.message || "") ? 409 : 400;
    return reply({ error: error.message || "Government FTO import failed." }, status);
  }
  if (!data || data.ok !== true) return reply({ error: "The database did not confirm the Government FTO import." }, 500);
  return reply({
    approved: true,
    batch_count: Number(data.batch_count) || 0,
    transaction_count: Number(data.transaction_count) || 0,
    status_history_count: Number(data.status_history_count) || 0,
    ledger_rows_created: Number(data.ledger_rows_created) || 0,
    batches: data.batches || [],
  });
});
