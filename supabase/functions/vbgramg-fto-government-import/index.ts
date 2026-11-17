import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://enga018.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Max-Age": "86400",
  "Content-Type": "application/json",
};
function reply(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Cache-Control": "no-store" } });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed." }, 405);

  const authorization = req.headers.get("Authorization") || "";
  const bearer = authorization.replace(/^Bearer\\s+/i, "");
  if (!bearer || bearer === authorization) return reply({ error: "Sign in required." }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete." }, 500);

  const auth = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: claimsData, error: claimsError } = await auth.auth.getClaims(bearer);
  const claims = claimsData?.claims;
  if (claimsError || !claims || typeof claims.sub !== "string" || typeof claims.email !== "string" ||
      claims.app_metadata?.email_verified !== true)
    return reply({ error: "A verified account is required." }, 401);

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const email = claims.email.trim().toLowerCase();
  const { data: approved, error: approvalError } = await admin.from("vbgramg_approved_users")
    .select("email,role").eq("email", email).maybeSingle();
  if (approvalError) return reply({ error: "Could not verify app access." }, 500);
  if (!approved || approved.role !== "admin")
    return reply({ error: "Only an approved VBGRAMG administrator can import Government FTO history." }, 403);

  try {
    const body = await req.json();
    if (!body || typeof body !== "object" || !Array.isArray(body.ftos) || body.ftos.length < 1 || body.ftos.length > 50)
      return reply({ error: "Select between one and fifty new FTOs to import." }, 400);
    if (typeof body.activeImportId !== "string" || typeof body.misUpdatedAt !== "string")
      return reply({ error: "The reviewed Active MIS snapshot is missing. Fetch and review FTO details again." }, 400);

    // Only accept newly inspected FTOs. The database RPC independently rejects
    // existing FTO numbers and validates every transaction against Active MIS.
    const seen = new Set<string>();
    for (const fto of body.ftos) {
      const number = String(fto?.ftoNumber || "").trim().toUpperCase();
      if (!number || seen.has(number)) return reply({ error: "The selection contains a missing or duplicate FTO number." }, 400);
      seen.add(number);
      if (!Array.isArray(fto.rows) || fto.rows.length < 1)
        return reply({ error: "Every selected FTO must contain its reviewed Government transaction rows." }, 400);
      if (fto.rows.some((row: any) => String(row?.ftoNumber || "").trim().toUpperCase() !== number))
        return reply({ error: "A transaction row has an inconsistent FTO number." }, 400);
    }

    const payload = {
      activeImportId: body.activeImportId,
      misUpdatedAt: body.misUpdatedAt,
      sourceSha256: typeof body.sourceSha256 === "string" ? body.sourceSha256 : null,
      ftos: body.ftos,
    };
    const { data, error } = await admin.rpc("vbgramg_import_government_fto_history", {
      p_payload: payload,
      p_actor: claims.sub,
    });
    if (error) {
      const message = error.message || "Government FTO history import failed.";
      return reply({ success: false, error: message, databaseChanged: false }, 409);
    }
    return reply({
      success: true,
      databaseChanged: true,
      contributionPeriodAssigned: false,
      ledgerRowsCreated: 0,
      result: data,
      message: "Government FTO transaction history imported. No Contribution period or charges were created.",
    });
  } catch (error) {
    return reply({ success: false, error: error instanceof Error ? error.message : "Government FTO import failed.", databaseChanged: false }, 400);
  }
});
