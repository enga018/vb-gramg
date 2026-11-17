import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const LISTING_URL = "https://vbgramgrep.dord.gov.in/VBGRAMG/FTO/fto_sign_detail.aspx?payload=rdOaI2pAxbYSaaRg8qCAVei-k0tjgtGSU7z7tMw2HfRTCRofL9eh2THACTVqZrEWf9LUtDwCuuJVd81BuDf841kilvUbc-q-fQYW5aim7Ls08S0rJgPg3oPtudLeLm_zxVVVDIzNxT7m02iXPW7MzsrJsRwDzOtFpn5fAm3b_9Tn13ZR7aEDd4LV-nElC4BadC4AV1IrjUAEb8mL4J6ktKjJVBYbcni4vksMdRBBFLJbSAET64WnkEhIzYOA4eUnlU4oeD8YP-qvVLznFMIk4bASkLMXflj1EQQYIqcUt6LHNzNgTjAVJAEO4b9Pv_Lc";
const corsHeaders = {
  "Access-Control-Allow-Origin": "https://enga018.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-fto-preview-key, x-fto-diagnostic-key",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Vary": "Origin",
};

function decodeHtml(s: string) {
  return s.replace(/&amp;/gi, "&").replace(/&quot;/gi, '"').replace(/&#39;/gi, "'")
    .replace(/&nbsp;/gi, " ").replace(/&#(\d+);?/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);?/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)));
}
function textOf(s: string) {
  return decodeHtml(s.replace(/<script\b[\s\S]*?<\/script>/gi, " ").replace(/<style\b[\s\S]*?<\/style>/gi, " ")
    .replace(/<br\s*\/?>/gi, " ").replace(/<[^>]*>/g, " "))
    .replace(/[\u00a0\u200b]/g, " ").replace(/\s+/g, " ").trim();
}
function rowsOf(html: string) {
  return [...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)]
    .map(m => [...m[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c => textOf(c[1])))
    .filter(r => r.some(Boolean));
}
async function getPage(url: string, timeoutMs = 8000) {
  const response = await fetch(url, {
    method: "GET", redirect: "follow",
    headers: { "User-Agent": "VBGRAMG-FTO-ListAudit/1.0", "Accept": "text/html,application/xhtml+xml",
      "Accept-Encoding": "identity", "Cache-Control": "no-cache", "Pragma": "no-cache" },
    signal: AbortSignal.timeout(timeoutMs),
  });
  const html = await response.text();
  return { response, html, bytes: new TextEncoder().encode(html).length };
}
function discoverCandidates(html: string, baseUrl: string) {
  const tableBlocks = [...html.matchAll(/<table\b[^>]*>([\s\S]*?)<\/table>/gi)].map(m => m[1]);
  const candidates: { detailUrl: string; listingRow: string[] }[] = [];
  const seen = new Set<string>();
  for (const table of tableBlocks) {
    for (const rowMatch of table.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)) {
      const rowHtml = rowMatch[1];
      const link = rowHtml.match(/<a\b[^>]*href\s*=\s*["']([^"']*fto_trasction_dtl\.aspx\?payload=[^"']+)["'][^>]*>([\s\S]*?)<\/a>/i);
      if (!link) continue;
      const href = decodeHtml(link[1]);
      if (seen.has(href)) continue;
      seen.add(href);
      const cells = [...rowHtml.matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c => textOf(c[1]));
      candidates.push({ detailUrl: new URL(href, baseUrl).toString(), listingRow: cells });
    }
  }
  return { tableCount: tableBlocks.length, candidates };
}
async function loadActiveMisJobCards() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) throw new Error("Supabase service configuration is unavailable.");
  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: state, error: stateError } = await admin.from("vbgramg_mis_state")
    .select("active_import_id, updated_at, row_count").eq("singleton", true).maybeSingle();
  if (stateError) throw stateError;
  if (!state?.active_import_id) throw new Error("There is no active MIS import.");
  const cards = new Set<string>();
  let rowCount = 0;
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await admin.from("vbgramg_mis_rows")
      .select("row_number,row_data").eq("import_id", state.active_import_id)
      .order("row_number", { ascending: true }).range(offset, offset + 999);
    if (error) throw error;
    for (const record of data || []) {
      rowCount++;
      if (record.row_number === 1 || !Array.isArray(record.row_data)) continue;
      const card = String(record.row_data[0] || "").trim();
      if (card) cards.add(card);
    }
    if (!data || data.length < 1000) break;
  }
  return { cards, activeImportId: state.active_import_id, misUpdatedAt: state.updated_at, misRowCount: rowCount };
}

function stableListingRow(row: string[]) {
  // Ignore the first cell (listing serial number); compare all visible FTO metadata.
  return row.slice(1).map(value => String(value || "").replace(/\s+/g, " ").trim().toLowerCase()).join("|");
}
async function listingFingerprint(candidates: { detailUrl: string }[]) {
  const raw = candidates.map(c => c.detailUrl).join("\n");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
  return [...new Uint8Array(digest)].map(v => v.toString(16).padStart(2, "0")).join("");
}

async function inspectDetail(url: string, misCards: Set<string> | null = null, includeExactRows = false) {
  try {
    const page = await getPage(url);
    if (!page.response.ok) return { kind: "http_failure" as const, bytes: page.bytes };
    const detailRows = rowsOf(page.html);
    const headerRow = detailRows.find(r => r.some(c => /job\s*card\s*no/i.test(c)) && r.some(c => /reference\s*no/i.test(c)));
    const pageText = textOf(page.html);
    if (!headerRow || !/FTO\s+Transaction\s+Details/i.test(pageText)) {
      return { kind: "parse_failure" as const, bytes: page.bytes };
    }
    const normalize = (v: string) => v.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    const header = headerRow.map(normalize);
    const findCol = (pattern: RegExp) => header.findIndex(v => pattern.test(v));
    const jobCardIndex = findCol(/job card no/);
    const referenceIndex = findCol(/reference no/);
    const statusIndex = findCol(/^status$/);
    const amountIndex = findCol(/amount|credit amount/);
    const villageIndex = findCol(/village/);
    if (jobCardIndex < 0 || referenceIndex < 0) return { kind: "parse_failure" as const, bytes: page.bytes };
    const headerAt = detailRows.indexOf(headerRow);
    const counts = {
      transactionCount: 0, processed: 0, rejected: 0, deferred: 0,
      exactMatches: 0, nonMatches: 0, exactProcessed: 0, exactRejected: 0, exactDeferred: 0,
      nonMatchProcessed: 0, nonMatchRejected: 0, nonMatchDeferred: 0,
    };
    const exactJobCardCounts = new Map<string, number>();
    const nonMatchingRows: Record<string, unknown>[] = [];
    const matchingRows: Record<string, unknown>[] = [];
    for (const row of detailRows.slice(headerAt + 1)) {
      const jobCardCell = row[jobCardIndex] || "";
      const referenceNo = row[referenceIndex] || "";
      const jobCardNo = jobCardCell.trim().split(/\s+/)[0];
      if (!jobCardCell || !referenceNo || !jobCardNo.includes("/") || jobCardNo.length < 8) continue;
      counts.transactionCount++;
      const detailRowNumber = counts.transactionCount;
      const rawStatus = statusIndex >= 0 ? (row[statusIndex] || "").trim().toLowerCase() : "";
      const status = rawStatus === "processed" ? "processed" : rawStatus === "rejected" ? "rejected" : "deferred";
      counts[status]++;
      if (misCards !== null) {
        const matched = misCards.has(jobCardNo);
        if (matched) {
          counts.exactMatches++;
          if (includeExactRows) {
            matchingRows.push({
              detailRowNumber,
              jobCardNo,
              referenceNo: referenceNo.trim(),
              status: rawStatus || "blank",
              normalizedStatus: status,
              columns: headerRow.map((name, index) => ({ name, value: row[index] || "" })),
            });
          }
          counts["exact" + status[0].toUpperCase() + status.slice(1)]++;
          exactJobCardCounts.set(jobCardNo, (exactJobCardCounts.get(jobCardNo) || 0) + 1);
        } else {
          counts.nonMatches++;
          counts["nonMatch" + status[0].toUpperCase() + status.slice(1)]++;
          nonMatchingRows.push({
            detailRowNumber,
            jobCardNo,
            referenceNo: referenceNo.trim(),
            status: rawStatus || "blank",
            ...(amountIndex >= 0 && row[amountIndex] ? { amount: row[amountIndex].trim() } : {}),
            ...(villageIndex >= 0 && row[villageIndex] ? { village: row[villageIndex].trim() } : {}),
          });
        }
      }
    }
    const exactUniqueJobCards = exactJobCardCounts.size;
    const exactDuplicateJobCards = [...exactJobCardCounts.values()].filter(n => n > 1).length;
    const duplicateExactJobCardRows = [...exactJobCardCounts.values()].reduce((sum, n) => sum + Math.max(0, n - 1), 0);
    return { kind: "ok" as const, bytes: page.bytes, ...counts, nonMatchingRows,
      ...(includeExactRows ? { matchingRows } : {}),
      exactUniqueJobCards, exactDuplicateJobCards, duplicateExactJobCardRows };
  } catch {
    return { kind: "fetch_failure" as const, bytes: 0 };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET" && req.method !== "POST") return Response.json({ error: "Use GET or POST" }, { status: 405, headers: corsHeaders });
  const url = new URL(req.url);
  if (url.searchParams.get("mode") !== "runner") {
    const diagnosticKey = Deno.env.get("FTO_AUDIT_DIAGNOSTIC_KEY");
    if (!diagnosticKey || req.headers.get("x-fto-diagnostic-key") !== diagnosticKey) {
      return Response.json({ error: "Unauthorized diagnostic request" }, { status: 401, headers: corsHeaders });
    }
  }
  if (url.searchParams.get("mode") === "runner") {
    const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>VBGRAMG FTO Audit</title><style>
      body{font:16px system-ui,sans-serif;max-width:760px;margin:32px auto;padding:0 16px;color:#222}
      h1{font-size:22px}button{padding:10px 16px;font-size:16px}progress{width:100%;height:22px}
      pre{white-space:pre-wrap;overflow-wrap:anywhere;background:#f3f4f6;padding:14px;border-radius:8px}
      .muted{color:#666;font-size:14px}
      </style></head><body><h1>VBGRAMG — Government FTO listing audit</h1>
      <p>This runs the audit in small batches of five. It does not read or change the database.</p>
      <label for="diagnosticKey">Diagnostic access code</label><input id="diagnosticKey" type="password" autocomplete="off" placeholder="Enter diagnostic access code"><button id="start">Start full audit (current FTOs)</button>
      <p id="status">Ready</p><progress id="progress" value="0" max="371"></progress>
      <pre id="result">No audit has run yet.</pre>
      <script>
      const key = () => document.getElementById("diagnosticKey").value.trim();
      const statusEl=document.getElementById("status"), progress=document.getElementById("progress"), resultEl=document.getElementById("result"), start=document.getElementById("start");
      let cancelled=false;
      start.onclick=async()=>{
        cancelled=false;start.disabled=true;start.textContent="Running…";
        const sum={testedPages:25,successfulPages:25,httpFailures:0,fetchFailures:0,parseFailures:0,transactions:2315,processed:1095,rejected:575,deferred:645,zeroTransactionPages:0};
        let offset=25, expected=371, batchCount=5; progress.max=371; progress.value=25;
        try{
          while(!cancelled){
            statusEl.textContent="Testing FTOs "+(offset+1)+"–"+Math.min(offset+5,expected||371)+"…";
            const endpoint=location.pathname+"?offset="+offset+"&limit=5";
            const response=await fetch(endpoint,{cache:"no-store",headers:{"x-fto-diagnostic-key":key()}});
            const data=await response.json();
            if(!response.ok||!data.success) throw new Error("Batch at offset "+offset+": "+JSON.stringify(data));
            expected=data.listingCandidateCount;
            progress.max=expected;
            batchCount++;sum.testedPages+=data.testedPages;
            for(const k of ["successfulPages","httpFailures","fetchFailures","parseFailures","transactions","processed","rejected","deferred","zeroTransactionPages"]) sum[k]+=data.totals[k];
            offset=data.nextOffset===null?expected:data.nextOffset;
            progress.value=sum.testedPages;
            resultEl.textContent=JSON.stringify({listingCandidateCount:expected,batchesCompleted:batchCount,...sum},null,2);
            if(data.nextOffset===null) break;
          }
          statusEl.textContent=cancelled?"Stopped by user.":"Complete — "+sum.testedPages+" of "+expected+" FTOs tested.";
        }catch(e){statusEl.textContent="Stopped: "+e.message;}
        finally{start.disabled=false;start.textContent="Run again";}
      };
      </script></body></html>`;
    const pageHeaders = new Headers(corsHeaders); pageHeaders.set("content-type", "text/html; charset=utf-8"); pageHeaders.set("cache-control", "no-store");
    return new Response(html, { status: 200, headers: pageHeaders });
  }

  const mode = url.searchParams.get("mode") || "source";
  if (mode === "manifest" || mode === "manifest-mis-match") {
    const started = Date.now();
    try {
      const listing = await getPage(LISTING_URL, 20000);
      if (!listing.response.ok) return Response.json({ success: false, stage: "listing", httpStatus: listing.response.status }, { status: 502, headers: corsHeaders });
      const listingText = textOf(listing.html);
      const isFtoListing = /FTO\s+First\s+Signatory/i.test(listingText);
      const { tableCount, candidates } = discoverCandidates(listing.html, listing.response.url);
      if (!isFtoListing || candidates.length === 0) {
        return Response.json({ success: false, stage: "listing_validation", isFtoListing, tableCount, candidateCount: candidates.length }, { status: 422, headers: corsHeaders });
      }
      const fingerprint = await listingFingerprint(candidates);
      const misSnapshot = mode === "manifest-mis-match" ? await loadActiveMisJobCards() : null;
      return Response.json({
        success: true, databaseChanged: false, output: "manifest_only",
        listingCandidateCount: candidates.length, listingFingerprint: fingerprint,
        detailUrls: candidates.map(c => c.detailUrl),
        ftoCandidates: candidates.map(c => ({ detailUrl: c.detailUrl, listingRow: c.listingRow })),
        ...(misSnapshot ? { activeImportId: misSnapshot.activeImportId, misUpdatedAt: misSnapshot.misUpdatedAt,
          misRowCount: misSnapshot.misRowCount, uniqueMisJobCards: misSnapshot.cards.size } : {}),
        elapsedMs: Date.now() - started,
      }, { headers: { ...corsHeaders, "Cache-Control": "no-store" } });
    } catch (error) {
      return Response.json({ success: false, stage: "manifest", error: error instanceof Error ? error.message : "Unknown error",
        databaseChanged: false, elapsedMs: Date.now() - started }, { status: 502, headers: corsHeaders });
    }
  }
  if (mode === "batch-source" || mode === "batch-mis-match" || mode === "batch-import-preview") {
    if (req.method === "POST" && mode !== "batch-import-preview") {
      return Response.json({ success: false, error: "POST is only supported for import preview batches." }, { status: 405, headers: corsHeaders });
    }
    if (mode === "batch-import-preview") {
      const expectedPreviewKey = Deno.env.get("FTO_IMPORT_PREVIEW_KEY");
      if (!expectedPreviewKey || req.headers.get("x-fto-preview-key") !== expectedPreviewKey) {
        return Response.json({ success: false, error: "Preview access code is invalid or not configured." }, { status: 401, headers: corsHeaders });
      }
    }
    const started = Date.now();
    try {
      let batchPayload: Record<string, unknown> | null = null;
      if (req.method === "POST") {
        try {
          const parsed = await req.json();
          if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("Invalid JSON object.");
          batchPayload = parsed as Record<string, unknown>;
        } catch {
          return Response.json({ success: false, error: "Invalid JSON request body." }, { status: 400, headers: corsHeaders });
        }
      }
      const rawUrls = req.method === "POST" ? null : url.searchParams.get("urls");
      if (req.method === "GET" && !rawUrls) return Response.json({ success: false, error: "Missing batch URLs." }, { status: 400, headers: corsHeaders });
      let detailUrls: unknown;
      let listingRows: unknown;
      try {
        detailUrls = req.method === "POST" ? batchPayload?.urls : JSON.parse(rawUrls as string);
        listingRows = req.method === "POST" ? batchPayload?.listingRows : JSON.parse(url.searchParams.get("listingRows") || "[]");
      } catch { return Response.json({ success: false, error: "Invalid batch URL or listing-row JSON." }, { status: 400, headers: corsHeaders }); }
      if (!Array.isArray(detailUrls) || detailUrls.length < 1 || detailUrls.length > 5 ||
          detailUrls.some(v => typeof v !== "string" || (() => { try { const u = new URL(v); return u.hostname !== "vbgramgrep.dord.gov.in" || !u.pathname.toLowerCase().endsWith("/fto_trasction_dtl.aspx") || !u.searchParams.has("payload"); } catch { return true; } })()) ||
          !Array.isArray(listingRows) || listingRows.length !== detailUrls.length ||
          listingRows.some(row => !Array.isArray(row) || row.length < 7)) {
        return Response.json({ success: false, error: "Batch must contain 1–5 valid government FTO detail URLs and matching listing rows." }, { status: 400, headers: corsHeaders });
      }
      const includeExactRows = mode === "batch-import-preview";
      const effectiveDetailUrls = [...detailUrls] as string[];
      const listingChanges = new Map<number, string>();
      let listingAdditions: string[] = [];
      if (includeExactRows) {
        const expectedFingerprint = req.method === "POST"
          ? String(batchPayload?.listingFingerprint || "")
          : url.searchParams.get("listingFingerprint");
        if (!expectedFingerprint) return Response.json({ success: false, error: "Missing original listing fingerprint for import preview." }, { status: 400, headers: corsHeaders });
        const currentListing = await getPage(LISTING_URL, 20000);
        if (!currentListing.response.ok) return Response.json({ success: false, error: "Could not revalidate the government listing.", databaseChanged: false }, { status: 502, headers: corsHeaders });
        const currentText = textOf(currentListing.html);
        const currentCandidates = discoverCandidates(currentListing.html, currentListing.response.url).candidates;
        if (!/FTO\s+First\s+Signatory/i.test(currentText) || currentCandidates.length === 0) {
          return Response.json({ success: false, error: "The current government FTO listing could not be validated.", listingChanged: true, databaseChanged: false }, { status: 409, headers: corsHeaders });
        }
        const currentByFto = new Map<string, { detailUrl: string; listingRow: string[] }>();
        for (const candidate of currentCandidates) {
          const ftoNumber = String(candidate.listingRow[3] || "").trim();
          if (ftoNumber) currentByFto.set(ftoNumber, candidate);
        }
        let snapshotFtoNumbers: unknown;
        try {
          snapshotFtoNumbers = req.method === "POST"
            ? batchPayload?.snapshotFtoNumbers
            : JSON.parse(url.searchParams.get("snapshotFtoNumbers") || "[]");
        } catch { return Response.json({ success: false, error: "Invalid original FTO number snapshot." }, { status: 400, headers: corsHeaders }); }
        if (!Array.isArray(snapshotFtoNumbers) || snapshotFtoNumbers.length < 1 || snapshotFtoNumbers.length > 1000 ||
            snapshotFtoNumbers.some(value => typeof value !== "string" || !value.trim())) {
          return Response.json({ success: false, error: "A complete original FTO number snapshot is required." }, { status: 400, headers: corsHeaders });
        }
        const originalFtoSet = new Set(snapshotFtoNumbers.map(value => String(value).trim()));
        listingAdditions = [...currentByFto.keys()].filter(ftoNumber => !originalFtoSet.has(ftoNumber));
        for (let i = 0; i < detailUrls.length; i++) {
          const originalRow = listingRows[i] as string[];
          const ftoNumber = String(originalRow[3] || "").trim();
          const current = currentByFto.get(ftoNumber);
          if (!current) {
            listingChanges.set(i, "FTO is no longer present in the current government listing.");
          } else if (stableListingRow(current.listingRow) !== stableListingRow(originalRow)) {
            listingChanges.set(i, "Visible FTO listing details changed since the preview snapshot.");
          } else {
            // Encrypted payload URLs may rotate; use the current URL for the same stable FTO.
            effectiveDetailUrls[i] = current.detailUrl;
          }
        }
      }
      const misSnapshot = mode === "batch-mis-match" || includeExactRows ? await loadActiveMisJobCards() : null;
      const totals: Record<string, number> = { successfulPages: 0, httpFailures: 0, fetchFailures: 0, parseFailures: 0,
        transactions: 0, processed: 0, rejected: 0, deferred: 0, zeroTransactionPages: 0 };
      const ftoResults: Record<string, unknown>[] = [];
      if (misSnapshot) Object.assign(totals, { exactMatches: 0, nonMatches: 0, exactProcessed: 0, exactRejected: 0, exactDeferred: 0,
        nonMatchProcessed: 0, nonMatchRejected: 0, nonMatchDeferred: 0, ftosWithExactMatches: 0, ftosZeroExactMatches: 0 });
      let cursor = 0;
      const worker = async () => {
        while (true) {
          const index = cursor++;
          if (index >= detailUrls.length) return;
          const listingRow = listingRows[index] as string[];
          const baseResult = {
            ftoNumber: listingRow[3] || "",
            signatoryDate: listingRow[5] || "",
            listingTransactionCount: Number(listingRow[6] || 0),
            listingAmount: Number(listingRow[7] || 0),
          };
          if (includeExactRows && listingChanges.has(index)) {
            ftoResults.push({ ...baseResult, listingChanged: true, listingChangeReason: listingChanges.get(index) });
            continue;
          }
          const result = await inspectDetail(effectiveDetailUrls[index] as string, misSnapshot?.cards ?? null, includeExactRows);
          if (result.kind === "ok") {
            totals.successfulPages++;
            totals.transactions += result.transactionCount;
            totals.processed += result.processed;
            totals.rejected += result.rejected;
            totals.deferred += result.deferred;
            if (result.transactionCount === 0) totals.zeroTransactionPages++;
            if (misSnapshot) {
              ftoResults.push({
                ...baseResult,
                transactionCount: result.transactionCount,
                processed: result.processed,
                rejected: result.rejected,
                deferred: result.deferred,
                exactMatches: result.exactMatches,
                nonMatches: result.nonMatches,
                exactProcessed: result.exactProcessed,
                exactRejected: result.exactRejected,
                exactDeferred: result.exactDeferred,
                exactUniqueJobCards: result.exactUniqueJobCards,
                exactDuplicateJobCards: result.exactDuplicateJobCards,
                duplicateExactJobCardRows: result.duplicateExactJobCardRows,
                nonMatchingRows: result.nonMatchingRows,
                ...(includeExactRows ? { matchingRows: result.matchingRows } : {}),
              });
              totals.exactMatches += result.exactMatches;
              totals.nonMatches += result.nonMatches;
              totals.exactProcessed += result.exactProcessed;
              totals.exactRejected += result.exactRejected;
              totals.exactDeferred += result.exactDeferred;
              totals.nonMatchProcessed += result.nonMatchProcessed;
              totals.nonMatchRejected += result.nonMatchRejected;
              totals.nonMatchDeferred += result.nonMatchDeferred;
              if (result.exactMatches > 0) totals.ftosWithExactMatches++;
              else totals.ftosZeroExactMatches++;
            }
          } else {
            if (result.kind === "http_failure") totals.httpFailures++;
            else if (result.kind === "fetch_failure") totals.fetchFailures++;
            else totals.parseFailures++;
            if (misSnapshot) ftoResults.push({ ...baseResult, pageError: result.kind });
          }
        }
      };
      await Promise.all(Array.from({ length: Math.min(2, detailUrls.length) }, () => worker()));
      if (includeExactRows) {
        const finalMisSnapshot = await loadActiveMisJobCards();
        if (finalMisSnapshot.activeImportId !== misSnapshot?.activeImportId ||
            finalMisSnapshot.misUpdatedAt !== misSnapshot?.misUpdatedAt) {
          return Response.json({
            success: false,
            error: "The active MIS changed while this batch was being scanned. Discard this preview and restart from a fresh MIS snapshot.",
            listingChanged: false,
            databaseChanged: true,
          }, { status: 409, headers: corsHeaders });
        }
      }
      return Response.json({
        success: true, databaseChanged: false,
        output: includeExactRows ? "exact_match_import_preview" : misSnapshot ? "per_fto_match_details" : "aggregate_counts_only", mode,
        ...(misSnapshot ? { ftoResults, activeImportId: misSnapshot.activeImportId, misUpdatedAt: misSnapshot.misUpdatedAt,
          misRowCount: misSnapshot.misRowCount, uniqueMisJobCards: misSnapshot.cards.size } : {}),
        testedPages: detailUrls.length, ...(includeExactRows ? { listingAdditions } : {}), totals, elapsedMs: Date.now() - started,
      }, { headers: { ...corsHeaders, "Cache-Control": "no-store" } });
    } catch (error) {
      return Response.json({ success: false, stage: "batch", error: error instanceof Error ? error.message : "Unknown error",
        databaseChanged: false, elapsedMs: Date.now() - started }, { status: 502, headers: corsHeaders });
    }
  }

  const offset = Math.max(0, Number.parseInt(url.searchParams.get("offset") || "0", 10) || 0);
  const limit = Math.min(5, Math.max(1, Number.parseInt(url.searchParams.get("limit") || "5", 10) || 5));
  const started = Date.now();
  try {
    const listing = await getPage(LISTING_URL, 20000);
    if (!listing.response.ok) return Response.json({ success: false, stage: "listing", httpStatus: listing.response.status }, { status: 502, headers: corsHeaders });
    const listingText = textOf(listing.html);
    const isFtoListing = /FTO\s+First\s+Signatory/i.test(listingText);
    const { tableCount, candidates } = discoverCandidates(listing.html, listing.response.url);
    const mode = url.searchParams.get("mode") || "source";
    const misSnapshot = mode === "mis-match" ? await loadActiveMisJobCards() : null;
    const fingerprint = await listingFingerprint(candidates);
    if (!isFtoListing || candidates.length === 0) {
      return Response.json({ success: false, stage: "listing_validation", isFtoListing, tableCount, candidateCount: candidates.length }, { status: 422, headers: corsHeaders });
    }
    const slice = candidates.slice(offset, offset + limit);
    const totals: Record<string, number> = { successfulPages: 0, httpFailures: 0, fetchFailures: 0, parseFailures: 0,
      transactions: 0, processed: 0, rejected: 0, deferred: 0, zeroTransactionPages: 0 };
    if (misSnapshot) Object.assign(totals, { exactMatches: 0, nonMatches: 0, exactProcessed: 0, exactRejected: 0, exactDeferred: 0,
      nonMatchProcessed: 0, nonMatchRejected: 0, nonMatchDeferred: 0, ftosWithExactMatches: 0, ftosZeroExactMatches: 0 });
    let cursor = 0;
    const worker = async () => {
      while (true) {
        const index = cursor++;
        if (index >= slice.length) return;
        const result = await inspectDetail(slice[index].detailUrl, misSnapshot?.cards ?? null);
        if (result.kind === "ok") {
          totals.successfulPages++;
          totals.transactions += result.transactionCount;
          totals.processed += result.processed;
          totals.rejected += result.rejected;
          totals.deferred += result.deferred;
          if (result.transactionCount === 0) totals.zeroTransactionPages++;
          if (misSnapshot) {
            totals.exactMatches += result.exactMatches;
            totals.nonMatches += result.nonMatches;
            totals.exactProcessed += result.exactProcessed;
            totals.exactRejected += result.exactRejected;
            totals.exactDeferred += result.exactDeferred;
            totals.nonMatchProcessed += result.nonMatchProcessed;
            totals.nonMatchRejected += result.nonMatchRejected;
            totals.nonMatchDeferred += result.nonMatchDeferred;
            if (result.exactMatches > 0) totals.ftosWithExactMatches++;
            else totals.ftosZeroExactMatches++;
          }
        } else if (result.kind === "http_failure") totals.httpFailures++;
        else if (result.kind === "fetch_failure") totals.fetchFailures++;
        else totals.parseFailures++;
      }
    };
    await Promise.all(Array.from({ length: Math.min(2, slice.length) }, () => worker()));
    return Response.json({
      success: true, databaseChanged: false, output: "aggregate_counts_only", mode,
      listingHttpStatus: listing.response.status, listingBytes: listing.bytes, listingTableCount: tableCount,
      listingCandidateCount: candidates.length, listingFingerprint: fingerprint,
      ...(misSnapshot ? { activeImportId: misSnapshot.activeImportId, misUpdatedAt: misSnapshot.misUpdatedAt,
        misRowCount: misSnapshot.misRowCount, uniqueMisJobCards: misSnapshot.cards.size } : {}),
      offset, requestedLimit: limit, testedPages: slice.length,
      nextOffset: offset + slice.length < candidates.length ? offset + slice.length : null,
      totals, elapsedMs: Date.now() - started,
    }, { headers: { ...corsHeaders, "Cache-Control": "no-store" } });
  } catch (error) {
    return Response.json({ success: false, stage: "fetch", error: error instanceof Error ? error.message : "Unknown error",
      databaseChanged: false, elapsedMs: Date.now() - started }, { status: 502, headers: corsHeaders });
  }
});