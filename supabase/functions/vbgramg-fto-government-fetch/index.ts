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
  const candidates: { detailUrl: string; listingRow: string[]; listingHeaders: string[]; ftoNumber: string }[] = [];
  const seen = new Set<string>();
  for (const table of html.matchAll(/<table\b[^>]*>([\s\S]*?)<\/table>/gi)) {
    const tableRows = [...table[1].matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)];
    const cellValues = (rowHtml: string) =>
      [...rowHtml.matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(cell => textOf(cell[1]));
    const dataRowIndexes = tableRows
      .map((row, index) => ({ row, index }))
      .filter(({ row }) => /<a\b[^>]*href\s*=\s*["'][^"']*fto_trasction_dtl\.aspx\?payload=/i.test(row[1]));
    for (const { row, index } of dataRowIndexes) {
      const href = row[1].match(/<a\b[^>]*href\s*=\s*["']([^"']*fto_trasction_dtl\.aspx\?payload=[^"']+)["'][^>]*>/i)?.[1];
      if (!href) continue;
      const detail = new URL(decodeHtml(href), baseUrl);
      if (detail.hostname !== "vbgramgrep.dord.gov.in" || detail.pathname.toLowerCase() !== "/vbgramg/fto/fto_trasction_dtl.aspx" || !detail.searchParams.has("payload")) continue;
      const detailUrl = detail.toString();
      if (seen.has(detailUrl)) continue;
      seen.add(detailUrl);
      const listingRow = cellValues(row[1]);
      // Some Government ASP.NET grids render header cells as <td>, not <th>.
      // Search backward from the first data row for a non-link row with the
      // same number of cells; do not assume a particular header tag.
      let listingHeaders: string[] = [];
      for (let prior = index - 1; prior >= 0; prior--) {
        const priorHtml = tableRows[prior][1];
        if (/<a\b/i.test(priorHtml)) continue;
        const values = cellValues(priorHtml);
        if (values.length === listingRow.length && values.some(value => /[A-Za-z]/.test(value))) {
          listingHeaders = values;
          break;
        }
      }
      candidates.push({ detailUrl, listingRow, listingHeaders, ftoNumber: String(listingRow[3] || "").trim() });
    }
  }
  return candidates;
}


async function makeManifestToken(serviceKey: string, candidates: { detailUrl: string; ftoNumber: string; listingRow: string[]; listingHeaders: string[] }[]) {
  const material = new TextEncoder().encode("VBGRAMG-FTO-MANIFEST-v1:" + serviceKey);
  const digest = await crypto.subtle.digest("SHA-256", material);
  const key = await crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const payload = new TextEncoder().encode(JSON.stringify({ v: 1, exp: Date.now() + 45 * 60 * 1000, candidates }));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, payload));
  const bytes = new Uint8Array(iv.length + encrypted.length); bytes.set(iv); bytes.set(encrypted, iv.length);
  let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
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
    if (!response.ok) return reply({ error: "Government listing request failed.", government_http_status: response.status, databaseChanged: false }, 502);
    if (new URL(response.url).hostname !== "vbgramgrep.dord.gov.in") return reply({ error: "The Government listing redirected to an unexpected host. No data was saved.", databaseChanged: false }, 502);
    const pageText = textOf(html);
    if (!/FTO\s+First\s+Signatory/i.test(pageText)) return reply({ error: "The response did not validate as the Government FTO listing. No data was saved." }, 502);
    const candidates = discoverCandidates(html, response.url);
    if (!candidates.length) return reply({ error: "No valid FTO detail links were found in the Government listing. No data was saved.", databaseChanged: false }, 502);

    // Read only the imported FTO identifiers. Page the query to avoid silently
    // truncating history when the database grows beyond PostgREST's row limit.
    const existingNumbers = new Set<string>();
    for (let offset = 0; ; offset += 1000) {
      const { data: batches, error: batchError } = await admin
        .from("vbgramg_fto_batches")
        .select("fto_number")
        .order("fto_number", { ascending: true })
        .range(offset, offset + 999);
      if (batchError) throw new Error("Could not compare Government FTOs with imported history: " + batchError.message);
      for (const batch of batches || []) {
        const normalized = String(batch.fto_number || "").trim().toUpperCase();
        if (normalized) existingNumbers.add(normalized);
      }
      if (!batches || batches.length < 1000) break;
    }

    const newFtos: { ftoNumber: string; listingRow: string[] }[] = [];
    const alreadyImported: { ftoNumber: string; listingRow: string[] }[] = [];
    const unrecognized: { ftoNumber: string; listingRow: string[]; reason: string }[] = [];
    const seenNumbers = new Set<string>();
    for (const candidate of candidates) {
      const ftoNumber = String(candidate.ftoNumber || "").trim();
      const normalized = ftoNumber.toUpperCase();
      const item = { ftoNumber, listingRow: candidate.listingRow };
      if (!normalized) {
        unrecognized.push({ ...item, reason: "FTO number unavailable" });
      } else if (seenNumbers.has(normalized)) {
        // A repeated number in the same Government listing needs review; it is
        // not evidence that the FTO already exists in our database.
        unrecognized.push({ ...item, reason: "Duplicate FTO number in Government listing" });
      } else {
        seenNumbers.add(normalized);
        if (existingNumbers.has(normalized)) alreadyImported.push(item);
        else newFtos.push(item);
      }
    }

    // Inspection is separate from import. COMPLETE but unimported FTOs remain
    // available so a fresh secure preview token can be issued if an earlier one expired.
    // OUT_OF_SCOPE FTOs are permanently skipped; imported FTOs are excluded above.
    const { data: inspectionRows, error: inspectionError } = await admin
      .from("vbgramg_fto_inspection_state")
      .select("fto_number_normalized,classification,last_inspected_at");
    if (inspectionError) throw new Error("Could not load persistent FTO inspection state.");
    const inspectionByNumber = new Map((inspectionRows || []).map((row: any) => [
      String(row.fto_number_normalized || "").trim().toUpperCase(), String(row.classification || "")
    ]));
    const isOutOfScope = (item: { ftoNumber: string }) =>
      inspectionByNumber.get(item.ftoNumber.trim().toUpperCase()) === "OUT_OF_SCOPE";
    const skippedInspectedFtos = newFtos.filter(isOutOfScope);
    const eligibleNewFtos = newFtos.filter(item => !isOutOfScope(item));
    const manifestToken = await makeManifestToken(serviceKey, candidates.map(({ detailUrl, ftoNumber, listingRow, listingHeaders }) => ({ detailUrl, ftoNumber, listingRow, listingHeaders })));
    const fingerprintBytes = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(candidates.map(item => item.detailUrl).join("\n")));
    const listingFingerprint = [...new Uint8Array(fingerprintBytes)].map(value => value.toString(16).padStart(2, "0")).join("");
    return reply({
      success: true,
      databaseChanged: false,
      source: "government",
      fetchedAt: new Date().toISOString(),
      listingCandidateCount: candidates.length,
      newCount: eligibleNewFtos.length,
      skippedInspectedCount: skippedInspectedFtos.length,
      skippedInspectedFtos,
      alreadyImportedCount: alreadyImported.length,
      unrecognizedCount: unrecognized.length,
      listingFingerprint,
      manifestToken,
      manifestExpiresInSeconds: 2700,
      newFtos: eligibleNewFtos,
      alreadyImported,
      unrecognized,
      message: "Government listing fetched and compared with imported history. Imported and out-of-scope FTOs were excluded; eligible unimported FTOs are ready for inspection or import retry.",
    });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "Government listing fetch failed.", databaseChanged: false }, 502);
  }
});
