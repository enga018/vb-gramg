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
async function readJsonBody(req: Request, maxBytes: number) {
  const declaredLength = Number(req.headers.get("Content-Length") || 0);
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) throw new Error("Request body is too large.");
  if (!req.body) throw new Error("Request body is empty.");
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel();
      throw new Error("Request body is too large.");
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
  return JSON.parse(new TextDecoder().decode(bytes));
}
function tokenBytes(value: string) {
  if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length > 2_000_000) throw new Error("Invalid or oversized import preview token.");
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(padded); return Uint8Array.from(binary, c => c.charCodeAt(0));
}
async function openImportPreviewToken(token: string, serviceKey: string) {
  const bytes = tokenBytes(token);
  if (bytes.length < 29) throw new Error("Import preview token is incomplete.");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("VBGRAMG-FTO-IMPORT-PREVIEW-v1:" + serviceKey));
  const key = await crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, ["decrypt"]);
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, key, bytes.slice(12));
  const payload = JSON.parse(new TextDecoder().decode(clear));
  if (payload?.v !== 1 || !Number.isFinite(payload.exp) || payload.exp < Date.now() ||
      typeof payload.userId !== "string" || typeof payload.activeImportId !== "string" ||
      typeof payload.misUpdatedAt !== "string" || typeof payload.ftoNumber !== "string" ||
      !Array.isArray(payload.rows) || payload.rows.length < 1 || payload.rows.length > 20000) {
    throw new Error("Import preview has expired or is invalid. Fetch and review FTO details again.");
  }
  return payload as { v:number; exp:number; userId:string; activeImportId:string; misUpdatedAt:string; ftoNumber:string; rows:any[] };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed." }, 405);
  const authorization = req.headers.get("Authorization") || "";
  const bearer = authorization.replace(/^Bearer\s+/i, "");
  if (!bearer || bearer === authorization) return reply({ error: "Sign in required." }, 401);
  const supabaseUrl = Deno.env.get("SUPABASE_URL"), anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete." }, 500);
  const auth = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: claimsData, error: claimsError } = await auth.auth.getClaims(bearer);
  const claims = claimsData?.claims;
  if (claimsError || !claims || typeof claims.sub !== "string" || typeof claims.email !== "string" ||
      claims.app_metadata?.email_verified !== true) return reply({ error: "A verified account is required." }, 401);
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approved, error: approvalError } = await admin.from("vbgramg_approved_users")
    .select("email,role").eq("email", claims.email.trim().toLowerCase()).maybeSingle();
  if (approvalError) return reply({ error: "Could not verify app access." }, 500);
  if (!approved || approved.role !== "admin") return reply({ error: "Only an approved VBGRAMG administrator can import Government FTO history." }, 403);
  try {
    const body = await readJsonBody(req, 10_000_000);
    if (!body || typeof body !== "object" || !Array.isArray(body.ftos) || body.ftos.length < 1 || body.ftos.length > 50)
      return reply({ error: "Select between one and fifty new FTOs to import." }, 400);
    const seen = new Set<string>(); const ftos = [];
    let activeImportId = "", misUpdatedAt = "";
    for (const selection of body.ftos) {
      const number = String(selection?.ftoNumber || "").trim().toUpperCase();
      const token = String(selection?.previewToken || "");
      if (!number || seen.has(number) || !token) return reply({ error: "The selection contains a missing or duplicate FTO number or preview token." }, 400);
      seen.add(number);
      const preview = await openImportPreviewToken(token, serviceKey);
      if (preview.userId !== claims.sub) return reply({ error: "This FTO preview was issued to a different administrator." }, 403);
      if (preview.ftoNumber.trim().toUpperCase() !== number) return reply({ error: "The preview token does not match the selected FTO." }, 400);
      if (activeImportId && (activeImportId !== preview.activeImportId || misUpdatedAt !== preview.misUpdatedAt))
        return reply({ error: "The selected previews were created from different Active MIS snapshots. Fetch details again." }, 409);
      activeImportId = preview.activeImportId; misUpdatedAt = preview.misUpdatedAt;
      if (preview.rows.some((row:any) => String(row?.ftoNumber || "").trim().toUpperCase() !== number))
        return reply({ error: "A signed preview contains an inconsistent FTO number." }, 400);
      ftos.push({ ftoNumber: preview.ftoNumber, rows: preview.rows });
    }
    const payload = { activeImportId, misUpdatedAt, sourceSha256: null, ftos };
    const { data, error } = await admin.rpc("vbgramg_import_government_fto_history", { p_payload: payload, p_actor: claims.sub });
    if (error) return reply({ success: false, error: error.message || "Government FTO history import failed.", databaseChanged: false }, 409);
    return reply({ success: true, databaseChanged: true, contributionPeriodAssigned: false, ledgerRowsCreated: 0,
      result: data, message: "Government FTO transaction history imported. No Contribution period or charges were created." });
  } catch (error) {
    return reply({ success: false, error: error instanceof Error ? error.message : "Government FTO import failed.", databaseChanged: false }, 400);
  }
});
