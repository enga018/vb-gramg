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
function normalizeApplicantName(value: unknown) {
  return String(value || "").normalize("NFKC").replace(/\s+/g, " ").trim().toLocaleLowerCase();
}
function normalizeApplicantIdentity(value: unknown) {
  return normalizeApplicantName(value).replace(/[^\p{L}\p{N}]+/gu, "");
}
function applicantNameScore(left: unknown, right: unknown) {
  const a = normalizeApplicantIdentity(left), b = normalizeApplicantIdentity(right);
  if (!a || !b) return 0;
  const prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let diagonal = prev[0]; prev[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const above = prev[j];
      prev[j] = Math.min(prev[j] + 1, prev[j - 1] + 1, diagonal + (a[i - 1] === b[j - 1] ? 0 : 1));
      diagonal = above;
    }
  }
  return Math.round((1 - prev[b.length] / Math.max(a.length, b.length)) * 1000) / 10;
}
async function loadActiveMisIndex(admin: any) {
  const { data: state, error: stateError } = await admin.from("vbgramg_mis_state")
    .select("active_import_id,row_count,source_filename").eq("singleton", true).maybeSingle();
  if (stateError) throw new Error("Could not load Active MIS state.");
  if (!state?.active_import_id) throw new Error("There is no Active MIS import. Load Active MIS before matching FTO transactions.");
  const records: any[] = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await admin.from("vbgramg_mis_rows").select("row_number,row_data")
      .eq("import_id", state.active_import_id).order("row_number", { ascending: true }).range(offset, offset + 999);
    if (error) throw new Error("Could not load Active MIS applicant records.");
    records.push(...(data || []));
    if (!data || data.length < 1000) break;
  }
  if (!records.length) throw new Error("Active MIS contains no rows.");
  const header = Array.isArray(records[0].row_data)
    ? records[0].row_data.map((v: unknown) => String(v || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim()) : [];
  const col = (...names: string[]) => header.findIndex((v: string) => names.includes(v));
  const jobCol = col("job card number", "jobcard number");
  const nameCol = col("name of applicant", "applicant name");
  const numberCol = col("applicant no", "applicant number");
  const uniqueCol = col("unique id", "unique applicant id");
  if (jobCol < 0 || nameCol < 0) throw new Error("Active MIS is missing Job Card Number or Name of Applicant columns.");
  const byCard = new Map<string, { applicantName: string; applicantNumber: string; applicantUniqueId: string }[]>();
  for (const record of records.slice(1)) {
    const row = Array.isArray(record.row_data) ? record.row_data : [];
    const card = String(row[jobCol] || "").trim().toUpperCase();
    const name = String(row[nameCol] || "").trim();
    if (!card || !name) continue;
    if (!byCard.has(card)) byCard.set(card, []);
    byCard.get(card)!.push({
      applicantName: name,
      applicantNumber: numberCol >= 0 ? String(row[numberCol] || "").trim() : "",
      applicantUniqueId: uniqueCol >= 0 ? String(row[uniqueCol] || "").trim() : ""
    });
  }
  const { data: exemptions, error: exemptionError } = await admin.from("vbgramg_contribution_exemptions")
    .select("job_card_number");
  if (exemptionError) throw new Error("Could not load Contribution exemption list.");
  return {
    importId: state.active_import_id,
    rowCount: Number(state.row_count) || records.length - 1,
    byCard,
    exemptCards: new Set((exemptions || []).map((r: any) => String(r.job_card_number || "").trim().toUpperCase()))
  };
}
function matchTransactionToMis(tx: Record<string, string>, index: Awaited<ReturnType<typeof loadActiveMisIndex>>) {
  const card = String(tx.jobCardNumber || "").trim().toUpperCase();
  const applicants = index.byCard.get(card);
  if (!card || !applicants?.length) return { misMatchStatus: "not_in_active_mis", misApplicant: null, misCandidates: [] };
  const person = String(tx.personName || "").trim();
  if (!person) return { misMatchStatus: "applicant_review", misApplicant: null, misCandidates: applicants.map(a => ({ ...a, matchPercentage: 0 })) };
  const ranked = applicants.map(a => ({ ...a, matchPercentage: applicantNameScore(person, a.applicantName) }))
    .sort((a, b) => b.matchPercentage - a.matchPercentage || a.applicantName.localeCompare(b.applicantName));
  const exact = ranked.filter(a => normalizeApplicantIdentity(a.applicantName) === normalizeApplicantIdentity(person));
  if (exact.length === 1) return { misMatchStatus: "matched", misApplicant: exact[0], misCandidates: ranked.slice(0, 3) };
  return { misMatchStatus: "applicant_review", misApplicant: null, misCandidates: ranked.slice(0, 3) };
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
  return manifest as { v: number; exp: number; candidates: { detailUrl: string; ftoNumber: string; listingRow: string[]; listingHeaders?: string[] }[] };
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
    const byNumber = new Map<string, { detailUrl: string; ftoNumber: string; listingRow: string[]; listingHeaders?: string[] }>();
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
    const { data: inspectionRows, error: inspectionError } = await admin.from("vbgramg_fto_inspection_state")
      .select("fto_number_normalized,classification")
      .in("fto_number_normalized", selected.map(item => item.ftoNumber.trim().toUpperCase()));
    if (inspectionError) throw new Error("Could not verify persistent FTO inspection state.");
    const inspectionByNumber = new Map((inspectionRows || []).map(row => [
      String(row.fto_number_normalized).trim().toUpperCase(), String(row.classification)
    ]));
    const batchIds = [...imported.values()];
    const deferredIds = new Set<string>();
    for (let start = 0; start < batchIds.length; start += 500) {
      const { data: txs, error } = await admin.from("vbgramg_fto_transactions").select("batch_id")
        .eq("is_current", true).in("status", ["blank", "deferred"]).in("batch_id", batchIds.slice(start, start + 500));
      if (error) throw new Error("Could not verify Deferred transaction status.");
      for (const tx of txs || []) deferredIds.add(String(tx.batch_id));
    }
    for (const item of selected) {
      const normalized = item.ftoNumber.trim().toUpperCase();
      const classification = inspectionByNumber.get(normalized);
      if (classification === "COMPLETE" || classification === "OUT_OF_SCOPE") {
        throw new Error("This FTO has already been inspected and is permanently excluded from future detail fetching.");
      }
      const batchId = imported.get(normalized);
      if (!classification && batchId && !deferredIds.has(batchId)) {
        throw new Error("An already-imported FTO is no longer Deferred and cannot be re-fetched in this run.");
      }
    }
    const misIndex = await loadActiveMisIndex(admin);
    const results: Record<string, unknown>[] = [];
    let cursor = 0;
    const workers = Array.from({ length: Math.min(2, selected.length) }, async () => {
      while (cursor < selected.length) {
        const item = selected[cursor++];
        try {
          const detail = await getPage(item.detailUrl);
          if (detail.kind === "ok") {
            const transactions = detail.transactions.map(tx => {
              const match = matchTransactionToMis(tx, misIndex);
              const exempt = misIndex.exemptCards.has(String(tx.jobCardNumber || "").trim().toUpperCase());
              return { ...tx, ...match, contributionExempt: exempt };
            });
            const inScope = transactions.filter(tx => tx.misMatchStatus !== "not_in_active_mis");
            const matchingCards = new Set(inScope.map(tx => String(tx.jobCardNumber || "").trim().toUpperCase()).filter(Boolean));
            const deferredInScope = inScope.filter(tx => tx.status === "deferred").length;
            const classification = matchingCards.size === 0 ? "OUT_OF_SCOPE" :
              deferredInScope > 0 ? "RECHECK_REQUIRED" : "COMPLETE";
            const { error: stateWriteError } = await admin.from("vbgramg_fto_inspection_state").upsert({
              fto_number_normalized: item.ftoNumber.trim().toUpperCase(),
              fto_number: item.ftoNumber.trim(),
              classification,
              last_inspected_at: new Date().toISOString(),
              matching_job_card_count: matchingCards.size,
              deferred_transaction_count: deferredInScope,
              transaction_count: transactions.length,
              updated_at: new Date().toISOString()
            }, { onConflict: "fto_number_normalized" });
            if (stateWriteError) throw new Error("Could not save FTO inspection state.");
            results.push({ ftoNumber: item.ftoNumber, inspectionClassification: classification,
              matchingJobCardCount: matchingCards.size, deferredInScopeCount: deferredInScope,
              signatoryDate: item.listingRow[5] || "", listingTransactionCount: Number(item.listingRow[6] || 0),
              listingAmount: Number(item.listingRow[7] || 0), listingRow: item.listingRow,
              listingHeaders: item.listingHeaders || [], ...detail, transactions });
          } else {
            results.push({ ftoNumber: item.ftoNumber, signatoryDate: item.listingRow[5] || "", listingTransactionCount: Number(item.listingRow[6] || 0), listingAmount: Number(item.listingRow[7] || 0), listingRow: item.listingRow, listingHeaders: item.listingHeaders || [], ...detail });
          }
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
