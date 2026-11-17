import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://enga018.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};
const AUDIT_URL = "https://trtzhafgvqosjwrgckty.supabase.co/functions/v1/vbgramg-fto-list-audit";
const DIAGNOSTIC_KEY = "ftoaudit-2026-11-16-7b8f3d91c2e64a0b";
const EXPECTED = [
  { ftoNumber: "2207001000SSPAYREQ25082026114", count: 297 },
  { ftoNumber: "2207001000SSPAYREQ25082026117", count: 54 },
  { ftoNumber: "2207001000SSPAYREQ20082026365", count: 3 },
];

function reply(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}
function normalizeRow(row: Record<string, any>) {
  return {
    ftoNumber: String(row.ftoNumber || ""),
    signatoryDate: String(row.signatoryDate || ""),
    detailRowNumber: Number(row.detailRowNumber),
    jobCardNo: String(row.jobCardNo || ""),
    referenceNo: String(row.referenceNo || ""),
    status: String(row.status || ""),
    normalizedStatus: String(row.normalizedStatus || ""),
    columns: Array.isArray(row.columns)
      ? row.columns.map((c: Record<string, unknown>) => ({
          name: String(c?.name || ""),
          value: String(c?.value ?? ""),
        }))
      : [],
  };
}
function sortedRows(rows: Record<string, any>[]) {
  return rows.map(normalizeRow).sort((a, b) => a.referenceNo.localeCompare(b.referenceNo));
}
async function sha256(value: string) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((v) => v.toString(16).padStart(2, "0")).join("");
}
async function auditRequest(mode: string, body?: Record<string, unknown>, previewKey?: string) {
  const url = new URL(AUDIT_URL);
  url.searchParams.set("key", DIAGNOSTIC_KEY);
  url.searchParams.set("mode", mode);
  const headers: Record<string, string> = { "Cache-Control": "no-store" };
  const init: RequestInit = { method: "GET", headers, cache: "no-store" };
  if (body) {
    headers["Content-Type"] = "application/json";
    headers["x-fto-preview-key"] = previewKey || "";
    init.method = "POST";
    init.body = JSON.stringify(body);
  }
  const response = await fetch(url, init);
  const data = await response.json().catch(() => null);
  if (!response.ok || !data?.success) {
    const message = String(data?.error || "Government source revalidation failed.");
    throw new Error(message);
  }
  return data;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed." }, 405);

  const header = req.headers.get("Authorization") || "";
  const token = header.replace(/^Bearer\s+/i, "");
  if (!token || token === header) return reply({ error: "Sign in required." }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete." }, 500);

  const auth = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await auth.auth.getUser(token);
  if (authError || !authData.user || !authData.user.email_confirmed_at) {
    return reply({ error: "A verified account is required." }, 401);
  }

  const email = (authData.user.email || "").trim().toLowerCase();
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approved, error: approvedError } = await admin
    .from("vbgramg_approved_users").select("email,role").eq("email", email).maybeSingle();
  if (approvedError) {
    console.error("Administrator lookup failed:", approvedError);
    return reply({ error: "Could not verify administrator access." }, 500);
  }
  if (!approved || approved.role !== "admin") {
    return reply({ error: "Only an approved VBGRAMG administrator can import Government FTO batches." }, 403);
  }

  let raw = "";
  let payload: Record<string, any>;
  try {
    raw = await req.text();
    if (raw.length > 8_000_000) return reply({ error: "The import preview is too large." }, 413);
    payload = JSON.parse(raw);
  } catch {
    return reply({ error: "The import request is not valid JSON." }, 400);
  }
  if (!payload || typeof payload !== "object" || !payload.previewMeta || !Array.isArray(payload.ftos)) {
    return reply({ error: "The validated Government FTO preview payload is incomplete." }, 400);
  }
  if (payload.action !== undefined && payload.action !== "validate-only") {
    return reply({ error: "Unsupported Government FTO action." }, 400);
  }
  const validateOnly = payload.action === "validate-only";

  const previewKey = Deno.env.get("FTO_IMPORT_PREVIEW_KEY");
  if (!previewKey) return reply({ error: "Government source revalidation is not configured. No import was made." }, 503);

  try {
    const snapshot = payload.sourceSnapshot;
    if (!snapshot || !Array.isArray(snapshot.candidates) || !Array.isArray(snapshot.snapshotFtoNumbers)) {
      return reply({ error: "This preview file does not contain the listing snapshot required for live verification. Generate a fresh preview." }, 409);
    }
    if (snapshot.candidates.length !== 371 || snapshot.snapshotFtoNumbers.length !== 371 ||
        String(snapshot.listingFingerprint || "") !== String(payload.previewMeta.listingFingerprint || "")) {
      return reply({ error: "The Government listing snapshot is incomplete or inconsistent. Generate a fresh preview." }, 409);
    }

    const currentManifest = await auditRequest("manifest");
    const currentNumbers = (currentManifest.ftoCandidates || [])
      .map((x: Record<string, any>) => String(x?.listingRow?.[3] || "").trim()).sort();
    const originalNumbers = snapshot.snapshotFtoNumbers.map((x: unknown) => String(x || "").trim()).sort();
    if (Number(currentManifest.listingCandidateCount) !== 371 ||
        JSON.stringify(currentNumbers) !== JSON.stringify(originalNumbers)) {
      return reply({ error: "The Government FTO listing changed since this preview. Generate a fresh preview." }, 409);
    }

    const targetCandidates = new Map<string, Record<string, any>>();
    for (const candidate of snapshot.candidates) {
      const number = String(candidate?.listingRow?.[3] || "").trim();
      if (EXPECTED.some(x => x.ftoNumber === number)) targetCandidates.set(number, candidate);
    }
    if (targetCandidates.size !== 3) {
      return reply({ error: "The preview is missing one or more target FTO listing records." }, 409);
    }

    const ordered = EXPECTED.map(spec => {
      const candidate = targetCandidates.get(spec.ftoNumber)!;
      if (typeof candidate.detailUrl !== "string" || !Array.isArray(candidate.listingRow)) {
        throw new Error("A target FTO listing snapshot is malformed.");
      }
      return candidate;
    });
    const livePreview = await auditRequest("batch-import-preview", {
      urls: ordered.map(x => x.detailUrl),
      listingRows: ordered.map(x => x.listingRow),
      listingFingerprint: snapshot.listingFingerprint,
      snapshotFtoNumbers: snapshot.snapshotFtoNumbers,
    }, previewKey);

    if (livePreview.databaseChanged !== false ||
        livePreview.activeImportId !== payload.previewMeta.activeImportId ||
        livePreview.misUpdatedAt !== payload.previewMeta.misUpdatedAt ||
        Number(livePreview.testedPages) !== 3 ||
        (livePreview.listingAdditions || []).length !== 0 ||
        !Array.isArray(livePreview.ftoResults) || livePreview.ftoResults.length !== 3) {
      return reply({ error: "The active MIS or Government listing changed during live verification. Generate a fresh preview." }, 409);
    }

    const liveFtos: Record<string, any>[] = [];
    for (const spec of EXPECTED) {
      const live = livePreview.ftoResults.find((x: Record<string, any>) => x.ftoNumber === spec.ftoNumber);
      const uploaded = payload.ftos.find((x: Record<string, any>) => x.ftoNumber === spec.ftoNumber);
      if (!live || live.listingChanged || live.pageError ||
          Number(live.transactionCount) !== spec.count || Number(live.exactMatches) !== spec.count ||
          Number(live.nonMatches) !== 0 || Number(live.rejected) !== spec.count ||
          Number(live.processed) !== 0 || Number(live.deferred) !== 0 ||
          Number(live.duplicateExactJobCardRows) !== 0 || !Array.isArray(live.matchingRows) ||
          live.matchingRows.length !== spec.count || !uploaded || !Array.isArray(uploaded.rows)) {
        return reply({ error: "Live Government verification failed for " + spec.ftoNumber + ". Generate a fresh preview." }, 409);
      }
      const currentRows = live.matchingRows.map((row: Record<string, any>) => ({
        ...row, ftoNumber: spec.ftoNumber, signatoryDate: String(live.signatoryDate || ""),
      }));
      if (JSON.stringify(sortedRows(currentRows)) !== JSON.stringify(sortedRows(uploaded.rows))) {
        return reply({ error: "Government transaction details changed since the preview for " + spec.ftoNumber + ". No data was imported; generate a fresh preview." }, 409);
      }
      liveFtos.push({ ftoNumber: spec.ftoNumber, rows: currentRows });
    }

    if (validateOnly) {
      return reply({
        validated: true,
        live_source_verified: true,
        database_writes_performed: false,
        batch_count: liveFtos.length,
        transaction_count: liveFtos.reduce((sum, item) => sum + item.rows.length, 0),
        status_history_rows_expected: liveFtos.reduce((sum, item) => sum + item.rows.length, 0),
        ledger_rows_to_create: 0,
        fto_numbers: liveFtos.map((item) => item.ftoNumber),
      });
    }

    const trustedPayload = {
      previewMeta: {
        ...payload.previewMeta,
        sourceSha256: await sha256(raw),
      },
      ftos: liveFtos,
    };
    const { data, error } = await admin.rpc("vbgramg_import_rejected_fto_batches", {
      p_payload: trustedPayload,
      p_actor: authData.user.id,
    });
    if (error) {
      console.error("Government FTO import rejected:", error);
      const status = /already exists|duplicate|changed|does not match|expected|invalid|not open|active MIS/i.test(error.message || "") ? 409 : 400;
      return reply({ error: error.message || "Government FTO import failed." }, status);
    }
    if (!data || data.ok !== true) return reply({ error: "The database did not confirm the Government FTO import." }, 500);
    return reply({
      approved: true,
      live_source_verified: true,
      batch_count: Number(data.batch_count) || 0,
      transaction_count: Number(data.transaction_count) || 0,
      status_history_count: Number(data.status_history_count) || 0,
      ledger_rows_created: Number(data.ledger_rows_created) || 0,
      batches: data.batches || [],
    });
  } catch (error) {
    console.error("Government FTO import failed before database commit:", error);
    return reply({ error: error instanceof Error ? error.message : "Government FTO import failed." }, 502);
  }
});
