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
function decodeHtml(value: string) {
  return value.replace(/&amp;/gi, "&").replace(/&quot;/gi, '"').replace(/&#39;/gi, "'")
    .replace(/&nbsp;/gi, " ").replace(/&#(\d+);?/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);?/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)));
}
function textOf(value: string) {
  return decodeHtml(value.replace(/<script\b[\s\S]*?<\/script>/gi, " ").replace(/<style\b[\s\S]*?<\/style>/gi, " ")
    .replace(/<br\s*\/?\s*>/gi, " ").replace(/<[^>]*>/g, " ")).replace(/[\u00a0\u200b]/g, " ").replace(/\s+/g, " ").trim();
}
function rowsOf(html: string) {
  return [...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)]
    .map(m => [...m[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c => textOf(c[1])))
    .filter(row => row.some(Boolean));
}
function base64UrlToBytes(value: string) {
  if (!/^[A-Za-z0-9_-]+$/.test(value) || value.length > 2_000_000) throw new Error("Invalid or oversized manifest token.");
  const padded = value.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(padded); return Uint8Array.from(binary, c => c.charCodeAt(0));
}
async function openManifest(token: string, serviceKey: string) {
  const bytes = base64UrlToBytes(token);
  if (bytes.length < 29) throw new Error("Manifest token is incomplete.");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("VBGRAMG-FTO-MANIFEST-v1:" + serviceKey));
  const key = await crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, ["decrypt"]);
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, key, bytes.slice(12));
  const manifest = JSON.parse(new TextDecoder().decode(clear));
  if (manifest?.v !== 1 || !Number.isFinite(manifest.exp) || manifest.exp < Date.now() || !Array.isArray(manifest.candidates))
    throw new Error("Manifest has expired or is invalid. Fetch the Government listing again.");
  return manifest as { v: number; exp: number; candidates: { detailUrl: string; ftoNumber: string; listingRow: string[] }[] };
}
async function getPage(url: string) {
  const parsed = new URL(url);
  if (parsed.hostname !== "vbgramgrep.dord.gov.in" || parsed.pathname.toLowerCase() !== "/vbgramg/fto/fto_trasction_dtl.aspx" || !parsed.searchParams.has("payload"))
    throw new Error("A manifest entry failed Government URL validation.");
  const response = await fetch(url, {
    method: "GET", redirect: "follow",
    headers: { "User-Agent": "VBGRAMG-FTO-Importer/1.0", "Accept": "text/html,application/xhtml+xml",
      "Accept-Encoding": "identity", "Cache-Control": "no-cache", "Pragma": "no-cache" },
    signal: AbortSignal.timeout(8000),
  });
  const html = await response.text();
  if (!response.ok) return { kind: "http_failure", httpStatus: response.status, rows: [] as Record<string, string>[] };
  if (new URL(response.url).hostname !== "vbgramgrep.dord.gov.in") return { kind: "redirect_failure", rows: [] as Record<string, string>[] };
  const tableRows = rowsOf(html);
  const pageText = textOf(html);
  const header = tableRows.find(row => row.some(cell => /job\s*card\s*no/i.test(cell)) && row.some(cell => /reference\s*no/i.test(cell)));
  if (!header || !/FTO\s+Transaction\s+Details/i.test(pageText)) return { kind: "parse_failure", rows: [] as Record<string, string>[] };
  const normalize = (value: string) => value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const names = header.map(normalize);
  const find = (pattern: RegExp) => names.findIndex(name => pattern.test(name));
  const job = find(/job card no/), reference = find(/reference no/), status = find(/^status$/);
  const amount = find(/amount|credit amount/), village = find(/village/), person = find(/name of person|person name|applicant name/);
  if (job < 0 || reference < 0) return { kind: "parse_failure", rows: [] as Record<string, string>[] };
  const headerIndex = tableRows.indexOf(header);
  const transactions: Record<string, string>[] = [];
  for (const row of tableRows.slice(headerIndex + 1)) {
    const jobCell = row[job] || "", referenceNo = (row[reference] || "").trim();
    const jobCardNo = jobCell.trim().split(/\s+/)[0];
    if (!jobCardNo.includes("/") || jobCardNo.length < 8 || !referenceNo) continue;
    const rawStatus = status >= 0 ? (row[status] || "").trim() : "";
    transactions.push({
      jobCardNumber: jobCardNo,
      referenceNumber: referenceNo,
      status: /^processed$/i.test(rawStatus) ? "processed" : /^rejected$/i.test(rawStatus) ? "rejected" : "deferred",
      governmentStatus: rawStatus || "blank",
      amount: amount >= 0 ? (row[amount] || "").trim() : "",
      village: village >= 0 ? (row[village] || "").trim() : "",
      personName: person >= 0 ? (row[person] || "").trim() : "",
      sourceRow: JSON.stringify(header.map((name, index) => ({ name, value: row[index] || "" }))),
    });
  }
  return { kind: "ok", transactions };
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
  if (claimsError || !claims || typeof claims.email !== "string" || claims.app_metadata?.email_verified !== true)
    return reply({ error: "A verified account is required." }, 401);
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approved, error: approvalError } = await admin.from("vbgramg_approved_users")
    .select("email,role").eq("email", claims.email.trim().toLowerCase()).maybeSingle();
  if (approvalError) return reply({ error: "Could not verify app access." }, 500);
  if (!approved || approved.role !== "admin") return reply({ error: "Only an approved VBGRAMG administrator can fetch Government FTO details." }, 403);
  try {
    const body = await req.json();
    const token = String(body.manifestToken || "");
    const requested = Array.isArray(body.ftoNumbers) ? body.ftoNumbers.map((v: unknown) => String(v || "").trim()).filter(Boolean) : [];
    if (!token || requested.length < 1 || requested.length > 5 || new Set(requested.map(v => v.toUpperCase())).size !== requested.length)
      return reply({ error: "Provide a valid manifest and between one and five distinct FTO numbers." }, 400);
    const manifest = await openManifest(token, serviceKey);
    const byNumber = new Map<string, { detailUrl: string; ftoNumber: string; listingRow: string[] }>();
    for (const candidate of manifest.candidates) {
      const key = String(candidate.ftoNumber || "").trim().toUpperCase();
      if (key && !byNumber.has(key)) byNumber.set(key, candidate);
    }
    const selected = requested.map(number => {
      const candidate = byNumber.get(number.toUpperCase());
      if (!candidate) throw new Error("Requested FTO is not part of this Government listing manifest.");
      return candidate;
    });
    // Revalidate eligibility at request time: new FTOs, or imported FTOs with a
    // current blank/Deferred transaction. No writes are performed here.
    const { data: batches, error: batchError } = await admin.from("vbgramg_fto_batches")
      .select("id,fto_number").in("fto_number", selected.map(item => item.ftoNumber));
    if (batchError) throw new Error("Could not verify imported FTO history.");
    const imported = new Map((batches || []).map(row => [String(row.fto_number).trim().toUpperCase(), String(row.id)]));
    const batchIds = [...imported.values()];
    const deferredIds = new Set<string>();
    for (let start = 0; start < batchIds.length; start += 500) {
      const { data: txs, error } = await admin.from("vbgramg_fto_transactions").select("batch_id")
        .eq("is_current", true).in("status", ["blank", "deferred"]).in("batch_id", batchIds.slice(start, start + 500));
      if (error) throw new Error("Could not verify Deferred transaction status.");
      for (const tx of txs || []) deferredIds.add(String(tx.batch_id));
    }
    for (const item of selected) {
      const batchId = imported.get(item.ftoNumber.trim().toUpperCase());
      if (batchId && !deferredIds.has(batchId)) throw new Error("An already-imported FTO is no longer Deferred and cannot be re-fetched in this run.");
    }
    const results: Record<string, unknown>[] = [];
    let cursor = 0;
    const workers = Array.from({ length: Math.min(2, selected.length) }, async () => {
      while (cursor < selected.length) {
        const item = selected[cursor++];
        try {
          const detail = await getPage(item.detailUrl);
          results.push({ ftoNumber: item.ftoNumber, signatoryDate: item.listingRow[5] || "", listingTransactionCount: Number(item.listingRow[6] || 0), listingAmount: Number(item.listingRow[7] || 0), listingRow: item.listingRow, ...detail });
        } catch (error) {
          results.push({ ftoNumber: item.ftoNumber, kind: "fetch_failure", error: "Government detail request failed. Retry this FTO." });
        }
      }
    });
    await Promise.all(workers);
    results.sort((a, b) => requested.findIndex(v => v.toUpperCase() === String(a.ftoNumber).toUpperCase()) -
      requested.findIndex(v => v.toUpperCase() === String(b.ftoNumber).toUpperCase()));
    const successful = results.filter(item => item.kind === "ok").length;
    return reply({ success: true, databaseChanged: false, requestedCount: requested.length, successfulCount: successful,
      failedCount: results.length - successful, results,
      message: "Detail pages processed. Results are a read-only preview; no database records were changed." });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "FTO detail processing failed.", databaseChanged: false }, 400);
  }
});
