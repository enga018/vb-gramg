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
    .select("active_import_id,row_count,source_filename,updated_at").eq("singleton", true).maybeSingle();
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
  const activeCards = new Set<string>();
  for (const record of records.slice(1)) {
    const row = Array.isArray(record.row_data) ? record.row_data : [];
    const card = String(row[jobCol] || "").trim().toUpperCase();
    const name = String(row[nameCol] || "").trim();
    if (!card) continue;
    activeCards.add(card);
    if (!name) continue;
    if (!byCard.has(card)) byCard.set(card, []);
    byCard.get(card)!.push({
      applicantName: name,
      applicantNumber: numberCol >= 0 ? String(row[numberCol] || "").trim() : "",
      applicantUniqueId: uniqueCol >= 0 ? String(row[uniqueCol] || "").trim() : ""
    });
  }
  return {
    importId: state.active_import_id,
    misUpdatedAt: state.updated_at,
    rowCount: Number(state.row_count) || records.length - 1,
    byCard,
    activeCards
  };
}
function matchTransactionToMis(tx: Record<string, string>, index: Awaited<ReturnType<typeof loadActiveMisIndex>>) {
  const card = String(tx.jobCardNumber || "").trim().toUpperCase();
  const applicants = index.byCard.get(card) || [];
  if (!card || !index.activeCards.has(card)) return { misMatchStatus: "not_in_active_mis", misApplicant: null, misCandidates: [] };
  const person = String(tx.personName || "").trim();
  if (!person || !applicants.length) return { misMatchStatus: "applicant_review", misApplicant: null, misCandidates: applicants.map(a => ({ ...a, matchPercentage: 0 })) };
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
async function makeImportPreviewToken(serviceKey: string, userId: string, payload: Record<string, unknown>) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("VBGRAMG-FTO-IMPORT-PREVIEW-v1:" + serviceKey));
  const key = await crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const clear = new TextEncoder().encode(JSON.stringify({ v: 1, exp: Date.now() + 15 * 60 * 1000, userId, ...payload }));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, clear));
  const bytes = new Uint8Array(iv.length + encrypted.length); bytes.set(iv); bytes.set(encrypted, iv.length);
  let binary = ""; for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
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
  const cleaned = String(value || "").replace(/[₹,\s]/g, "").replace(/[^\d.-]/g, "");
  if (!cleaned) return "";
  const amount = Number(cleaned);
  return Number.isFinite(amount) && amount >= 0 ? String(amount) : "";
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
    if (!jobCardNumber || !referenceNumber) continue;
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
      amount: row[amountToBeCredited] || "",
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
      .select("fto_number_normalized,classification,inspection_data,matching_job_card_count,deferred_transaction_count,transaction_count,last_inspected_at")
      .in("fto_number_normalized", selected.map(item => item.ftoNumber.trim().toUpperCase()));
    if (inspectionError) throw new Error("Could not verify persistent FTO inspection state.");
    const inspectionByNumber = new Map((inspectionRows || []).map(row => [
      String(row.fto_number_normalized).trim().toUpperCase(), row
    ]));
    for (const item of selected) {
      const normalized = item.ftoNumber.trim().toUpperCase();
      const inspection = inspectionByNumber.get(normalized);
      const classification = inspection?.classification;
      if (imported.has(normalized)) {
        throw new Error("This FTO has already been imported and is permanently excluded from automatic detail fetching.");
      }
      if (classification === "OUT_OF_SCOPE") {
        throw new Error("This FTO was inspected and has no transactions matching an Active MIS Job Card. It is permanently excluded.");
      }
      // Previously inspected ELIGIBLE FTOs reuse their saved transaction rows.
      // Legacy inspection records without a payload are fetched once to populate it.
    }
    const misIndex = await loadActiveMisIndex(admin);
    const results: Record<string, unknown>[] = [];
    let newlyInspectedCount = 0;
    let reusedInspectionCount = 0;
    let cursor = 0;
    const workers = Array.from({ length: Math.min(2, selected.length) }, async () => {
      while (cursor < selected.length) {
        const item = selected[cursor++];
        try {
          const normalizedFto = item.ftoNumber.trim().toUpperCase();
          const savedInspection = inspectionByNumber.get(normalizedFto);
          const savedData = savedInspection?.inspection_data;
          const hasSavedTransactions = savedData && Array.isArray(savedData.transactions);
          const savedSnapshotIsCurrent = !hasSavedTransactions ||
            (String(savedData.activeImportId || "") === misIndex.importId &&
             String(savedData.misUpdatedAt || "") === String(misIndex.misUpdatedAt || ""));
          const detail = hasSavedTransactions
            ? { kind: "ok", transactions: savedData.transactions }
            : await getPage(item.detailUrl, item.ftoNumber);
          if (detail.kind === "ok") {
            const transactions = hasSavedTransactions
              ? detail.transactions
              : detail.transactions.map(tx => {
              const match = matchTransactionToMis(tx, misIndex);
              return { ...tx, ftoNumber: item.ftoNumber, ...match };
            });
            // Eligibility is based only on whether a transaction's full Job Card Number
            // exists in the reviewed Active MIS. Retain every transaction in the FTO,
            // including unmatched rows, for later review during Contribution charge creation.
            const matchingTransactions = transactions.filter(tx => tx.misMatchStatus !== "not_in_active_mis");
            const matchingCards = new Set(matchingTransactions.map(tx => String(tx.jobCardNumber || "").trim().toUpperCase()).filter(Boolean));
            const deferredInScope = matchingTransactions.filter(tx => tx.normalizedStatus === "blank").length;
            const classification = matchingCards.size === 0 ? "OUT_OF_SCOPE" : "ELIGIBLE";
            if (!hasSavedTransactions) {
              const inspectionData = {
                transactions,
                listingRow: item.listingRow,
                listingHeaders: item.listingHeaders || [],
                signatoryDate: item.listingRow[5] || "",
                listingTransactionCount: Number(item.listingRow[6] || 0),
                listingAmount: Number(item.listingRow[7] || 0),
                activeImportId: misIndex.importId,
                misUpdatedAt: misIndex.misUpdatedAt
              };
              const { error: stateWriteError } = await admin.from("vbgramg_fto_inspection_state").upsert({
                fto_number_normalized: normalizedFto,
                fto_number: item.ftoNumber.trim(),
                classification,
                inspection_data: inspectionData,
                last_inspected_at: new Date().toISOString(),
                matching_job_card_count: matchingCards.size,
                deferred_transaction_count: deferredInScope,
                transaction_count: transactions.length,
                updated_at: new Date().toISOString()
              }, { onConflict: "fto_number_normalized" });
              if (stateWriteError) throw new Error("Could not save FTO inspection state.");
              newlyInspectedCount++;
            } else {
              reusedInspectionCount++;
            }
            const listingRow = hasSavedTransactions && Array.isArray(savedData.listingRow) ? savedData.listingRow : item.listingRow;
            const listingHeaders = hasSavedTransactions && Array.isArray(savedData.listingHeaders) ? savedData.listingHeaders : (item.listingHeaders || []);
            const result: Record<string, unknown> = { ftoNumber: item.ftoNumber, inspectionClassification: classification,
              matchingJobCardCount: matchingCards.size, importableTransactionCount: transactions.length,
              deferredInScopeCount: deferredInScope,
              inspectionSnapshotStale: hasSavedTransactions && !savedSnapshotIsCurrent,
              inspectionSnapshotInspectedAt: hasSavedTransactions ? (savedInspection?.last_inspected_at || null) : null,
              signatoryDate: hasSavedTransactions ? (savedData.signatoryDate || "") : (item.listingRow[5] || ""),
              listingTransactionCount: hasSavedTransactions ? Number(savedData.listingTransactionCount || 0) : Number(item.listingRow[6] || 0),
              listingAmount: hasSavedTransactions ? Number(savedData.listingAmount || 0) : Number(item.listingRow[7] || 0),
              listingRow, listingHeaders, kind: "ok", transactions };
            if (!imported.has(item.ftoNumber.trim().toUpperCase()) && matchingCards.size > 0 && savedSnapshotIsCurrent) {
              result.importPreviewToken = await makeImportPreviewToken(serviceKey, claims.sub, {
                activeImportId: hasSavedTransactions ? savedData.activeImportId : misIndex.importId,
                misUpdatedAt: hasSavedTransactions ? savedData.misUpdatedAt : misIndex.misUpdatedAt,
                ftoNumber: item.ftoNumber, rows: transactions
              });
            }
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
    return reply({ success: true, databaseChanged: newlyInspectedCount > 0, inspectionStateSaved: newlyInspectedCount > 0,
      newlyInspectedCount, reusedInspectionCount,
      misSnapshot: { activeImportId: misIndex.importId, misUpdatedAt: misIndex.misUpdatedAt },
      requestedCount: requested.length, successfulCount: successful,
      failedCount: results.length - successful, results,
      message: newlyInspectedCount > 0
        ? "New Government detail inspections were saved. Previously inspected eligible FTOs reused their saved transaction rows. FTO history and Contribution records were not changed."
        : "Previously inspected eligible FTOs reused their saved transaction rows. No new inspection records or Government detail requests were created." });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "FTO detail processing failed.", databaseChanged: false }, 400);
  }
});
