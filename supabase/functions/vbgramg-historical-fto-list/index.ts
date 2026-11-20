import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

// Historical recovery only. This endpoint never writes to the database.
const LISTING_URL = "https://mnregaweb4.dord.gov.in/netnrega/FTO/fto_sign_detail.aspx?payload=ccUNH2QD-jBtqXIcL3-j6MX8lvhCuyS-cL7T-XwqPV2tYpgrP-Bo-LBVefO7kQOy49ABahMPmB_CKMUV_US1Usi9i917_Fc4_z9FwbRxH364XZpXxIk8kDP1amLgUFXRKB-O4gVtVzNjRQeLAz2U-RUA1xSqZfTB1JYySr006XKuBxqpT2CU5ZMwDFmk1c6vQVhKSE8TDjeIthV9OWyj1ZEsTy521j9iXUdt_lxqZyACCJ00pSlZ58y_U5A5F3PgpgTBaaj3oLoGMhZJiRDuyP1t3fB8v1npN7vQZiZDYV-QYVOgjH_inx4l0XvQm0iY";
const HOST = "mnregaweb4.dord.gov.in";
const PATH = "/netnrega/fto/fto_trasction_dtl.aspx";
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
function decodeHtml(value: string) {
  return value.replace(/&amp;/gi, "&").replace(/&quot;/gi, '"').replace(/&#39;/gi, "'")
    .replace(/&nbsp;/gi, " ").replace(/&#(\d+);?/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);?/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)));
}
function textOf(value: string) {
  return decodeHtml(value.replace(/<script\b[\s\S]*?<\/script>/gi, " ").replace(/<style\b[\s\S]*?<\/style>/gi, " ")
    .replace(/<br\s*\/?\s*>/gi, " ").replace(/<[^>]*>/g, " "))
    .replace(/[\u00a0\u200b]/g, " ").replace(/\s+/g, " ").trim();
}
function parseListing(html: string, baseUrl: string) {
  const entries: { detailUrl: string; ftoNumber: string; listingRow: string[]; listingHeaders: string[]; listingIndex: number }[] = [];
  const seen = new Set<string>();
  for (const table of html.matchAll(/<table\b[^>]*>([\s\S]*?)<\/table>/gi)) {
    const rows = [...table[1].matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)];
    const cells = (source: string) => [...source.matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(m => textOf(m[1]));
    for (let i = 0; i < rows.length; i++) {
      const rowHtml = rows[i][1];
      const href = rowHtml.match(/<a\b[^>]*href\s*=\s*["']([^"']*fto_trasction_dtl\.aspx\?payload=[^"']+)["']/i)?.[1];
      if (!href) continue;
      const detail = new URL(decodeHtml(href), baseUrl);
      if (detail.protocol !== "https:" || detail.hostname !== HOST || detail.pathname.toLowerCase() !== PATH || !detail.searchParams.has("payload")) continue;
      const detailUrl = detail.toString();
      if (seen.has(detailUrl)) continue;
      seen.add(detailUrl);
      const listingRow = cells(rowHtml);
      let listingHeaders: string[] = [];
      for (let p = i - 1; p >= 0; p--) {
        if (/<a\b/i.test(rows[p][1])) continue;
        const candidate = cells(rows[p][1]);
        if (candidate.length === listingRow.length && candidate.some(v => /[A-Za-z]/.test(v))) { listingHeaders = candidate; break; }
      }
      entries.push({ detailUrl, ftoNumber: String(listingRow[3] || "").trim(), listingRow, listingHeaders, listingIndex: entries.length + 1 });
    }
  }
  return entries;
}
async function makeToken(serviceKey: string, candidates: ReturnType<typeof parseListing>) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("VBGRAMG-HISTORICAL-FTOS-v1:" + serviceKey));
  const key = await crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const clear = new TextEncoder().encode(JSON.stringify({ v: 1, exp: Date.now() + 60 * 60 * 1000, candidates }));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, clear));
  const bytes = new Uint8Array(iv.length + encrypted.length); bytes.set(iv); bytes.set(encrypted, iv.length);
  let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed." }, 405);
  const bearer = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!bearer) return reply({ error: "Sign in required." }, 401);
  const supabaseUrl = Deno.env.get("SUPABASE_URL"), anonKey = Deno.env.get("SUPABASE_ANON_KEY"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete." }, 500);
  const auth = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: claimsData, error: claimsError } = await auth.auth.getClaims(bearer);
  const claims = claimsData?.claims;
  if (claimsError || !claims || typeof claims.sub !== "string" || typeof claims.email !== "string" || claims.app_metadata?.email_verified !== true)
    return reply({ error: "A verified account is required." }, 401);
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approved, error } = await admin.from("vbgramg_approved_users").select("email,role")
    .eq("email", claims.email.trim().toLowerCase()).maybeSingle();
  if (error) return reply({ error: "Could not verify app access." }, 500);
  if (!approved || approved.role !== "admin") return reply({ error: "Only an approved VBGRAMG administrator can run historical FTO checks." }, 403);
  try {
    const response = await fetch(LISTING_URL, {
      method: "GET", redirect: "follow",
      headers: { "User-Agent": "VBGRAMG-Historical-FTO-Check/1.0", "Accept": "text/html,application/xhtml+xml", "Accept-Encoding": "identity", "Cache-Control": "no-cache" },
      signal: AbortSignal.timeout(25000),
    });
    const html = await response.text();
    if (!response.ok) return reply({ error: "Government listing request failed.", httpStatus: response.status, databaseChanged: false }, 502);
    if (new URL(response.url).hostname !== HOST) return reply({ error: "Government listing redirected to an unexpected host.", databaseChanged: false }, 502);
    if (!/FTO\s+First\s+Signatory/i.test(textOf(html))) return reply({ error: "Response did not validate as the expected First Signatory FTO listing.", databaseChanged: false }, 502);
    const candidates = parseListing(html, response.url);
    if (!candidates.length) return reply({ error: "No valid FTO transaction detail links were found.", databaseChanged: false }, 502);
    const numbers = candidates.map(x => x.ftoNumber.trim().toUpperCase()).filter(Boolean);
    if (candidates.length !== 975 || numbers.length !== 975 || new Set(numbers).size !== 975)
      return reply({ error: "The live listing did not match the verified 975-entry structure. No detail checks were started.", listingCount: candidates.length, uniqueFtoNumbers: new Set(numbers).size, databaseChanged: false }, 409);
    const manifestToken = await makeToken(serviceKey, candidates);
    return reply({
      success: true, databaseChanged: false, listingCount: candidates.length,
      uniqueFtoCount: new Set(numbers).size, source: LISTING_URL.split("?")[0],
      fetchedAt: new Date().toISOString(), manifestToken, manifestExpiresInSeconds: 3600,
      message: "Historical FTO listing loaded. No production records or inspection state were changed.",
    });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "Historical listing fetch failed.", databaseChanged: false }, 502);
  }
});
