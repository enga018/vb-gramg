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
async function loadActiveMisJobCards(admin: any) {
  const { data: state, error: stateError } = await admin.from("vbgramg_mis_state")
    .select("active_import_id,row_count,updated_at").eq("singleton", true).maybeSingle();
  if (stateError) throw new Error("Could not load Active MIS state.");
  if (!state?.active_import_id) throw new Error("There is no Active MIS import. Load Active MIS before inspecting FTOs.");
  const { data: headerRecord, error: headerError } = await admin.from("vbgramg_mis_rows")
    .select("row_data").eq("import_id", state.active_import_id).eq("row_number", 1).maybeSingle();
  if (headerError || !Array.isArray(headerRecord?.row_data)) throw new Error("Could not read the Active MIS header.");
  const header = headerRecord.row_data.map((v: unknown) => String(v || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim());
  const jobCol = header.findIndex((v: string) => ["job card number", "jobcard number"].includes(v));
  if (jobCol < 0) throw new Error("Active MIS is missing the Job Card Number column.");
  const activeCards = new Set<string>();
  for (let offset = 1; ; offset += 1000) {
    const { data, error } = await admin.from("vbgramg_mis_rows").select("row_data")
      .eq("import_id", state.active_import_id).gt("row_number", 1)
      .order("row_number", { ascending: true }).range(offset - 1, offset + 998);
    if (error) throw new Error("Could not load Active MIS Job Cards.");
    for (const record of data || []) {
      const row = Array.isArray(record.row_data) ? record.row_data : [];
      const card = String(row[jobCol] || "").trim().toUpperCase();
      if (card) activeCards.add(card);
    }
    if (!data || data.length < 1000) break;
  }
  return { importId: state.active_import_id, misUpdatedAt: state.updated_at, activeCards };
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
function parseGovernmentAmount(value: string) {
  const raw = String(value || "").trim().replace(/[₹,\s]/g, "");
  if (!raw || !/^\d+(?:\.\d+)?$/.test(raw)) return "";
  const amount = Number(raw);
  return Number.isFinite(amount) && amount >= 0 ? String(amount) : "";
}
function validateGovernmentTransactions(transactions: Record<string, any>[], listingRow: string[]) {
  const errors: string[] = [];
  const refs = new Set<string>();
  for (let index = 0; index < transactions.length; index++) {
    const tx = transactions[index], label = "Government row " + (index + 1);
    if (!tx.jobCardNumber) errors.push(label + ": missing or invalid Job Card Number.");
    if (!tx.referenceNumber) errors.push(label + ": missing Reference Number.");
    const ref = String(tx.referenceNumber || "").trim().toUpperCase();
    if (ref && refs.has(ref)) errors.push(label + ": duplicate Reference Number " + ref + ".");
    if (ref) refs.add(ref);
    if (!tx.creditAmount) errors.push(label + ": missing or invalid Credit Amount.");
    if (tx.normalizedStatus === "other") errors.push(label + ": unrecognized Government status.");
  }
  const sum = (rows: Record<string, any>[]) => rows.reduce((n, tx) => n + Number(tx.creditAmount || 0), 0);
  const countAt = (i: number) => { const v=String(listingRow[i]??"").replace(/,/g,"").trim(); return /^\d+$/.test(v)?Number(v):null; };
  const amountAt = (i: number) => { const v=String(listingRow[i]??"").replace(/[₹,\s]/g,""); return /^\d+(?:\.\d+)?$/.test(v)?Number(v):null; };
  const checks = [
    {label:"Processed count",expected:countAt(8),actual:transactions.filter(tx=>tx.normalizedStatus==="processed").length},
    {label:"Rejected count",expected:countAt(10),actual:transactions.filter(tx=>tx.normalizedStatus==="rejected").length},
    {label:"Processed amount",expected:amountAt(9),actual:sum(transactions.filter(tx=>tx.normalizedStatus==="processed"))},
    {label:"Rejected amount",expected:amountAt(11),actual:sum(transactions.filter(tx=>tx.normalizedStatus==="rejected"))},
    {label:"Total amount",expected:amountAt(7),actual:sum(transactions)}
  ];
  for (const c of checks) {
    if (c.expected===null) errors.push("Government listing "+c.label+" is missing or invalid.");
    else if (Math.abs(c.expected-c.actual)>=0.005) errors.push("Government listing "+c.label+" does not reconcile with detail rows.");
  }
  return errors;
}
function parseGovernmentDate(value: string) {
  const text = String(value || "").trim();
  if (!text) return "";
  const match = text.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})$/);
  if (match) return `${match[3]}-${match[2].padStart(2, "0")}-${match[1].padStart(2, "0")}`;
  if (/^\d{4}-\d{2}-\d{2}$/.test(text)) return text;
  return "";
}
function normalizeGovernmentStatus(value: string) {
  const raw = String(value || "").trim();
  if (!raw) return "blank";
  if (/^processed$/i.test(raw)) return "processed";
  if (/^rejected$/i.test(raw)) return "rejected";
  return "other";
}
function extractJobCard(value: string) {
  const match = String(value || "").match(/\bMZ-\d{2}-(?:\d{3}-){2,3}\d{3}\/\d+(?:-[A-Z]+)?\b/i);
  return match ? match[0].toUpperCase() : "";
}
function extractVillage(value: string, jobCardNumber: string) {
  return String(value || "").replace(jobCardNumber, " ").replace(/[()\[\]{}]/g, " ")
    .replace(/\s+/g, " ").replace(/^[\s,;:.-]+|[\s,;:.-]+$/g, "").trim();
}
async function getPage(url: string, ftoNumber: string) {
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
  if (!response.ok) return { kind: "http_failure", httpStatus: response.status, rows: [] as any[] };
  if (new URL(response.url).hostname !== "vbgramgrep.dord.gov.in") return { kind: "redirect_failure", rows: [] as any[] };
  const tableRows = rowsOf(html);
  const pageText = textOf(html);
  const header = tableRows.find(row => row.some(cell => /job\s*card\s*no/i.test(cell)) && row.some(cell => /reference\s*no/i.test(cell)));
  if (!header || !/FTO\s+Transaction\s+Details/i.test(pageText)) return { kind: "parse_failure", rows: [] as any[] };
  const normalize = (value: string) => value.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const names = header.map(normalize);
  const find = (...exactNames: string[]) => names.findIndex(name => exactNames.includes(name));
  const job = find("job card no panchayat name", "job card no", "job card number");
  const reference = find("reference no", "reference number");
  const transactionDate = find("transaction date");
  const applicant = find("applicant name", "name of applicant", "name of person");
  const primaryHolder = find("name of primary account holder");
  const amountToBeCredited = find("amount to be credited in rs", "amount to be credited");
  const creditAmount = find("credit amount in rs", "credit amount");
  const status = find("status");
  const processedDate = find("processed date");
  const rejectionReason = find("rejection reason");
  if (job < 0 || reference < 0 || amountToBeCredited < 0 || creditAmount < 0 || status < 0)
    return { kind: "parse_failure", rows: [] as any[] };
  const headerIndex = tableRows.indexOf(header);
  const transactions: Record<string, any>[] = [];
  for (const row of tableRows.slice(headerIndex + 1)) {
    const jobCell = row[job] || "";
    const jobCardNumber = extractJobCard(jobCell);
    const referenceNumber = (row[reference] || "").trim();
    if (!jobCardNumber || !referenceNumber) {
      transactions.push({ ftoNumber, jobCardNumber, referenceNumber,
        normalizedStatus: normalizeGovernmentStatus((row[status] || "").trim()),
        amountToBeCredited: parseGovernmentAmount(row[amountToBeCredited] || ""),
        creditAmount: parseGovernmentAmount(row[creditAmount] || ""),
        sourceRow: header.map((name, index) => ({ name, value: row[index] || "" })) });
      continue;
    }
    const rawStatus = (row[status] || "").trim();
    const normalizedStatus = normalizeGovernmentStatus(rawStatus);
    const personName = (row[applicant >= 0 ? applicant : primaryHolder] || "").trim();
    const village = extractVillage(jobCell, jobCardNumber);
    const sourceRow = header.map((name, index) => ({ name, value: row[index] || "" }));
    transactions.push({
      // Bind each parsed transaction to its parent FTO for the signed import contract.
      ftoNumber,
      // Keep the established preview keys while exposing the exact import contract.
      jobCardNumber,
      referenceNumber,
      status: normalizedStatus === "blank" ? "deferred" : normalizedStatus,
      normalizedStatus,
      governmentStatus: rawStatus || "blank",
      amount: row[creditAmount] || "",
      jobCardNo: jobCardNumber,
      referenceNo: referenceNumber,
      amountToBeCredited: parseGovernmentAmount(row[amountToBeCredited] || ""),
      creditAmount: parseGovernmentAmount(row[creditAmount] || ""),
      transactionDate: transactionDate >= 0 ? parseGovernmentDate(row[transactionDate] || "") : "",
      processedDate: processedDate >= 0 ? parseGovernmentDate(row[processedDate] || "") : "",
      rejectionReason: rejectionReason >= 0 ? (row[rejectionReason] || "").trim() : "",
      village,
      villageName: village,
      personName,
      sourceRow
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
  if (claimsError || !claims || typeof claims.sub !== "string" || typeof claims.email !== "string" || claims.app_metadata?.email_verified !== true)
    return reply({ error: "A verified account is required." }, 401);
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approved, error: approvalError } = await admin.from("vbgramg_approved_users")
    .select("email,role").eq("email", claims.email.trim().toLowerCase()).maybeSingle();
  if (approvalError) return reply({ error: "Could not verify app access." }, 500);
  if (!approved || approved.role !== "admin") return reply({ error: "Only an approved VBGRAMG administrator can fetch Government FTO details." }, 403);
  try {
    const body = await readJsonBody(req, 2_200_000);
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
    // Revalidate eligibility at request time. Imported FTOs are never re-fetched.
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
    for (const item of selected) {
      const normalized = item.ftoNumber.trim().toUpperCase();
      const classification = inspectionByNumber.get(normalized);
      if (imported.has(normalized)) {
        throw new Error("This FTO has already been imported and is permanently excluded from automatic detail fetching.");
      }
      if (classification === "OUT_OF_SCOPE") {
        throw new Error("This FTO was inspected and has no transactions matching an Active MIS Job Card. It is permanently excluded.");
      }
      if (classification === "ELIGIBLE") {
        throw new Error("This FTO has already been inspected. Continue from Pending Imports using the saved inspection; Government details must not be fetched again.");
      }
    }
    const misIndex = await loadActiveMisJobCards(admin);
    const results: Record<string, unknown>[] = [];
    let cursor = 0;
    const workers = Array.from({ length: Math.min(2, selected.length) }, async () => {
      while (cursor < selected.length) {
        const item = selected[cursor++];
        try {
          const detail = await getPage(item.detailUrl, item.ftoNumber);
          if (detail.kind === "ok") {
            const transactions = detail.transactions.map(tx => ({ ...tx, ftoNumber: item.ftoNumber }));
            const validationErrors = validateGovernmentTransactions(transactions, item.listingRow || []);
            if (validationErrors.length) {
              results.push({ ftoNumber: item.ftoNumber, kind: "validation_failure", validationErrors,
                governmentTransactionCount: transactions.length, listingRow: item.listingRow, listingHeaders: item.listingHeaders || [] });
              continue;
            }
            // Keep only Job Cards present in Active MIS; applicant-name mismatches remain reviewable.
            const governmentTransactionCount = transactions.length;
            const unmatchedTransactionCount = transactions.filter(tx => !misIndex.activeCards.has(String(tx.jobCardNumber || "").trim().toUpperCase())).length;
            const matchingTransactions = transactions.filter(tx => misIndex.activeCards.has(String(tx.jobCardNumber || "").trim().toUpperCase()));
            const matchingCards = new Set(matchingTransactions.map(tx => String(tx.jobCardNumber || "").trim().toUpperCase()).filter(Boolean));
            const deferredInScope = matchingTransactions.filter(tx => tx.normalizedStatus === "blank").length;
            const classification = matchingCards.size === 0 ? "OUT_OF_SCOPE" : "ELIGIBLE";
            const { error: stateWriteError } = await admin.from("vbgramg_fto_inspection_state").upsert({
              fto_number_normalized: item.ftoNumber.trim().toUpperCase(),
              fto_number: item.ftoNumber.trim(),
              classification,
              last_inspected_at: new Date().toISOString(),
              matching_job_card_count: matchingCards.size,
              deferred_transaction_count: deferredInScope,
              transaction_count: governmentTransactionCount,
              unmatched_transaction_count: unmatchedTransactionCount,
              validated_transactions: matchingTransactions,
              active_mis_import_id: misIndex.importId,
              active_mis_updated_at: misIndex.misUpdatedAt,
              updated_at: new Date().toISOString()
            }, { onConflict: "fto_number_normalized" });
            if (stateWriteError) throw new Error("Could not save FTO inspection state.");
            const result: Record<string, unknown> = { ftoNumber: item.ftoNumber, backendValidated: true, inspectionClassification: classification,
              matchingJobCardCount: matchingCards.size, importableTransactionCount: matchingTransactions.length,
              governmentTransactionCount, unmatchedTransactionCount,
              deferredInScopeCount: deferredInScope,
              signatoryDate: item.listingRow[5] || "", listingTransactionCount: Number(item.listingRow[6] || 0),
              listingAmount: Number(item.listingRow[7] || 0), listingRow: item.listingRow,
              listingHeaders: item.listingHeaders || [], ...detail };
            results.push(result);
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
    return reply({ success: true, databaseChanged: successful > 0, inspectionStateSaved: successful > 0,
      misSnapshot: { activeImportId: misIndex.importId, misUpdatedAt: misIndex.misUpdatedAt },
      requestedCount: requested.length, successfulCount: successful,
      failedCount: results.length - successful, results,
      message: "Detail pages validated. Eligible FTOs and their Active-MIS-matching transaction details were saved to Pending Imports. Applicant matching and FTO import have not been performed." });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "FTO detail processing failed.", databaseChanged: false }, 400);
  }
});
