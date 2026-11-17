import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const LISTING_URL = "https://vbgramgrep.dord.gov.in/VBGRAMG/FTO/fto_sign_detail.aspx?payload=rdOaI2pAxbYSaaRg8qCAVei-k0tjgtGSU7z7tMw2HfRTCRofL9eh2THACTVqZrEWf9LUtDwCuuJVd81BuDf841kilvUbc-q-fQYW5aim7Ls08S0rJgPg3oPtudLeLm_zxVVVDIzNxT7m02iXPW7MzsrJsRwDzOtFpn5fAm3b_9Tn13ZR7aEDd4LV-nElC4BadC4AV1IrjUAEb8mL4J6ktKjJVBYbcni4vksMdRBBFLJbSAET64WnkEhIzYOA4eUnlU4oeD8YP-qvVLznFMIk4bASkLMXflj1EQQYIqcUt6LHNzNgTjAVJAEO4b9Pv_Lc";

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
    .replace(/<br\s*\/?>/gi, " ").replace(/<[^>]*>/g, " ")).replace(/[\u00a0\u200b]/g, " ").replace(/\s+/g, " ").trim();
}
function discoverCandidates(html: string, baseUrl: string) {
  const candidates: { detailUrl: string; listingRow: string[]; ftoNumber: string }[] = [];
  const seen = new Set<string>();
  for (const table of html.matchAll(/<table\b[^>]*>([\s\S]*?)<\/table>/gi)) {
    for (const row of table[1].matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)) {
      const href = row[1].match(/<a\b[^>]*href\s*=\s*["']([^"']*fto_trasction_dtl\.aspx\?payload=[^"']+)["'][^>]*>/i)?.[1];
      if (!href) continue;
      const detailUrl = new URL(decodeHtml(href), baseUrl).toString();
      if (seen.has(detailUrl)) continue;
      seen.add(detailUrl);
      const listingRow = [...row[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(cell => textOf(cell[1]));
      candidates.push({ detailUrl, listingRow, ftoNumber: String(listingRow[3] || "").trim() });
    }
  }
  return candidates;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed." }, 405);

  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token || token === authorization) return reply({ error: "Sign in required." }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete." }, 500);

  const auth = createClient(supabaseUrl, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: claimsData, error: claimsError } = await auth.auth.getClaims(token);
  const claims = claimsData?.claims;
  if (claimsError || !claims || typeof claims.sub !== "string" || typeof claims.email !== "string" ||
      claims.app_metadata?.email_verified !== true) return reply({ error: "A verified account is required." }, 401);

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const email = claims.email.trim().toLowerCase();
  const { data: approved, error: approvalError } = await admin.from("vbgramg_approved_users")
    .select("email,role").eq("email", email).maybeSingle();
  if (approvalError) return reply({ error: "Could not verify app access." }, 500);
  if (!approved || approved.role !== "admin") return reply({ error: "Only an approved VBGRAMG administrator can fetch Government FTO data." }, 403);

  try {
    const response = await fetch(LISTING_URL, {
      method: "GET",
      redirect: "follow",
      headers: {
        "User-Agent": "VBGRAMG-FTO-Importer/1.0",
        "Accept": "text/html,application/xhtml+xml",
        "Accept-Encoding": "identity",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
      },
      signal: AbortSignal.timeout(20000),
    });
    const html = await response.text();
    if (!response.ok) return reply({ error: "Government listing request failed.", government_http_status: response.status }, 502);
    const pageText = textOf(html);
    if (!/FTO\s+First\s+Signatory/i.test(pageText)) return reply({ error: "The response did not validate as the Government FTO listing. No data was saved." }, 502);
    const candidates = discoverCandidates(html, response.url);
    if (!candidates.length) return reply({ error: "No FTO detail links were found in the Government listing. No data was saved." }, 502);
    const fingerprintBytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(candidates.map(item => item.detailUrl).join("\n")));
    const listingFingerprint = [...new Uint8Array(fingerprintBytes)].map(value => value.toString(16).padStart(2, "0")).join("");
    return reply({
      success: true,
      databaseChanged: false,
      source: "government",
      fetchedAt: new Date().toISOString(),
      listingCandidateCount: candidates.length,
      listingFingerprint,
      candidates,
      message: "Government listing fetched and validated. No FTO detail pages were fetched and no database records were changed.",
    });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "Government listing fetch failed.", databaseChanged: false }, 502);
  }
});
