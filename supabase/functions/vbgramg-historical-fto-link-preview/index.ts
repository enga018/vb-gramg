import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const HOST = "mnregaweb4.dord.gov.in";
const DETAIL_PATH = "/netnrega/fto/fto_trasction_dtl.aspx";
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
function normalizeCard(value: unknown) {
  return String(value || "").trim().toUpperCase().replace(/\s+/g, "");
}
function round2(value: number) { return Math.round((value + Number.EPSILON) * 100) / 100; }

async function openManifest(token: string, serviceKey: string) {
  if (!/^[A-Za-z0-9_-]+$/.test(token) || token.length > 2_000_000) throw new Error("Invalid manifest token.");
  const padded = token.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - token.length % 4) % 4);
  const bytes = Uint8Array.from(atob(padded), c => c.charCodeAt(0));
  if (bytes.length < 29) throw new Error("Manifest token is incomplete.");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("VBGRAMG-HISTORICAL-FTOS-v1:" + serviceKey));
  const key = await crypto.subtle.importKey("raw", digest, { name: "AES-GCM" }, false, ["decrypt"]);
  const clear = await crypto.subtle.decrypt({ name: "AES-GCM", iv: bytes.slice(0, 12) }, key, bytes.slice(12));
  const manifest = JSON.parse(new TextDecoder().decode(clear));
  if (manifest?.v !== 1 || !Number.isFinite(manifest.exp) || manifest.exp < Date.now() ||
      !Array.isArray(manifest.candidates) || manifest.candidates.length !== 975) {
    throw new Error("Manifest expired or invalid. Fetch the official listing again.");
  }
  return manifest as { v: number; exp: number; candidates: { ftoNumber: string; detailUrl: string }[] };
}
async function readBody(req: Request) {
  const raw = await req.text();
  if (raw.length > 2_100_000) throw new Error("Request is too large.");
  return JSON.parse(raw);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed." }, 405);
  const bearer = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!bearer) return reply({ error: "Sign in required." }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return reply({ error: "Server configuration is incomplete." }, 500);

  const auth = createClient(url, anon, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: claimsData, error: claimsError } = await auth.auth.getClaims(bearer);
  const claims = claimsData?.claims;
  if (claimsError || !claims || typeof claims.sub !== "string" || typeof claims.email !== "string" ||
      claims.app_metadata?.email_verified !== true) return reply({ error: "A verified account is required." }, 401);

  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approved, error: approvedError } = await admin.from("vbgramg_approved_users")
    .select("role").eq("email", claims.email.trim().toLowerCase()).maybeSingle();
  if (approvedError) return reply({ error: "Could not verify app access." }, 500);
  if (approved?.role !== "admin") return reply({ error: "Only an approved administrator can preview historical FTO links." }, 403);

  try {
    const body = await readBody(req);
    if (typeof body.manifestToken !== "string" || !Array.isArray(body.ftoNumbers) ||
        body.ftoNumbers.length < 1 || body.ftoNumbers.length > 25) {
      return reply({ error: "Provide a verified listing token and between one and 25 FTO numbers.", databaseChanged: false }, 400);
    }
    const manifest = await openManifest(body.manifestToken, service);
    const allowed = new Set(manifest.candidates.map(c => String(c.ftoNumber).trim().toUpperCase()));
    const ftoNumbers = body.ftoNumbers.map((v: unknown) => String(v || "").trim().toUpperCase());
    if (new Set(ftoNumbers).size !== ftoNumbers.length || ftoNumbers.some((n: string) => !allowed.has(n))) {
      return reply({ error: "Duplicate or unverified FTO number supplied.", databaseChanged: false }, 400);
    }

    const { data: batches, error: batchError } = await admin.from("vbgramg_fto_batches")
      .select("id,fto_number").in("fto_number", ftoNumbers);
    if (batchError) throw new Error("Could not load imported FTO batches.");
    const batchByNumber = new Map((batches || []).map((b: any) => [String(b.fto_number).trim().toUpperCase(), b]));
    const missing = ftoNumbers.filter((n: string) => !batchByNumber.has(n));
    if (missing.length) return reply({
      error: "These historical FTOs have not yet been imported: " + missing.join(", "),
      missingFtoNumbers: missing, databaseChanged: false,
    }, 409);

    const batchIds = ftoNumbers.map((n: string) => batchByNumber.get(n).id);
    const { data: txRows, error: txError } = await admin.from("vbgramg_fto_transactions")
      .select("id,batch_id,reference_no,job_card_number,village_name,person_name,transaction_date,processed_date,amount_to_be_credited,credit_amount,status,rejection_reason,ledger_entry_id,source_row,is_in_scope,is_current")
      .in("batch_id", batchIds).eq("is_current", true).order("job_card_number").order("reference_no");
    if (txError) throw new Error("Could not load imported historical FTO transactions.");

    const { data: periods, error: periodError } = await admin.from("vbgramg_periods")
      .select("id,period_name,period_date").gte("period_date", "2026-01-01").lt("period_date", "2026-07-01");
    if (periodError || !periods?.length) throw new Error("Could not load JAN26–JUN26 periods.");
    const periodById = new Map(periods.map((p: any) => [p.id, p]));
    const periodIds = periods.map((p: any) => p.id);

    const { data: charges, error: chargeError } = await admin.from("vbgramg_charge_ledger")
      .select("id,job_card_number,person_name,amount,charge_period,entry_date,period_id,is_voided,is_deferred")
      .eq("entry_type", "charge").eq("is_voided", false).in("period_id", periodIds)
      .order("job_card_number").order("entry_date");
    if (chargeError) throw new Error("Could not load historical Charge Ledger entries.");

    const cards = [...new Set((txRows || []).map((t: any) => normalizeCard(t.job_card_number)).filter(Boolean))];
    const { data: currentExemptions, error: currentExemptionError } = await admin.from("vbgramg_contribution_exemptions")
      .select("job_card_number,note").in("job_card_number", cards);
    if (currentExemptionError) throw new Error("Could not load current exemption records.");
    const { data: exemptionHistory, error: historyError } = await admin.from("vbgramg_contribution_exemption_history")
      .select("job_card_number,note,started_at,ended_at").in("job_card_number", cards);
    if (historyError) throw new Error("Could not load exemption history.");

    const chargesByCard = new Map<string, any[]>();
    for (const c of charges || []) {
      const card = normalizeCard(c.job_card_number);
      if (!chargesByCard.has(card)) chargesByCard.set(card, []);
      chargesByCard.get(card)!.push({ ...c, periodName: periodById.get(c.period_id)?.period_name || c.charge_period || "Unknown period" });
    }
    const currentExemptByCard = new Map((currentExemptions || []).map((e: any) => [normalizeCard(e.job_card_number), e]));
    const historyByCard = new Map<string, any[]>();
    for (const h of exemptionHistory || []) {
      const card = normalizeCard(h.job_card_number);
      if (!historyByCard.has(card)) historyByCard.set(card, []);
      historyByCard.get(card)!.push(h);
    }

    const preview = (txRows || []).map((tx: any) => {
      const card = normalizeCard(tx.job_card_number);
      const credit = tx.credit_amount == null ? null : Number(tx.credit_amount);
      const calculatedCharge = credit == null || !Number.isFinite(credit) ? null : round2(credit * 80 / 281);
      const candidates = (chargesByCard.get(card) || []).filter((c: any) =>
        calculatedCharge !== null && round2(Number(c.amount)) === calculatedCharge);
      const distinctPeriods = [...new Set(candidates.map((c: any) => c.periodName))];
      const alreadyLinked = tx.ledger_entry_id != null;
      const linkedCandidate = alreadyLinked ? candidates.find((c: any) => c.id === tx.ledger_entry_id) : null;
      const warnings: string[] = [];
      let proposedAction = "manual_review";
      let proposedChargeId: string | null = null;
      if (!tx.is_in_scope) warnings.push("Transaction is outside the imported village scope.");
      if (tx.status === "rejected") warnings.push("Rejected attempt: retain in FTO history; never link.");
      else if (tx.status !== "processed") warnings.push("Only Processed transactions are eligible for linking.");
      if (calculatedCharge === null) warnings.push("Credit Amount is missing or invalid.");
      if (alreadyLinked) warnings.push(linkedCandidate ? "Already linked to this matching charge." : "Already linked; inspect the existing link.");
      const history = historyByCard.get(card) || [];
      if (currentExemptByCard.has(card)) warnings.push("Currently exempt; current status does not prove historical exemption.");
      if (history.length) warnings.push("Exemption history exists; verify whether it overlaps the historical period.");
      if (tx.status === "processed" && tx.is_in_scope && !alreadyLinked && calculatedCharge !== null) {
        if (candidates.length === 1) {
          proposedAction = "propose_link";
          proposedChargeId = candidates[0].id;
        } else if (candidates.length === 0) warnings.push("No exact amount-matching charge found in JAN26–JUN26.");
        else warnings.push("Multiple exact amount-matching charges; period is ambiguous.");
      }
      return {
        transactionId: tx.id, ftoNumber: ftoNumbers.find((n: string) => batchByNumber.get(n).id === tx.batch_id),
        referenceNumber: tx.reference_no, jobCardNumber: tx.job_card_number, applicant: tx.person_name,
        status: tx.status, transactionDate: tx.transaction_date, processedDate: tx.processed_date,
        creditAmount: tx.credit_amount, amountToBeCredited: tx.amount_to_be_credited,
        calculatedCharge, existingLedgerEntryId: tx.ledger_entry_id,
        proposedAction, proposedChargeId,
        candidateCharges: candidates.map((c: any) => ({
          chargeId: c.id, periodId: c.period_id, periodName: c.periodName, amount: c.amount,
          entryDate: c.entry_date, isDeferred: c.is_deferred, personName: c.person_name,
        })),
        exemption: {
          currentlyExempt: currentExemptByCard.has(card),
          currentNote: currentExemptByCard.get(card)?.note || null,
          history: history.map((h: any) => ({ note: h.note, startedAt: h.started_at, endedAt: h.ended_at })),
        },
        warnings,
      };
    });

    const summary = {
      total: preview.length,
      proposedLinks: preview.filter((x: any) => x.proposedAction === "propose_link").length,
      manualReview: preview.filter((x: any) => x.proposedAction === "manual_review").length,
      rejected: preview.filter((x: any) => x.status === "rejected").length,
      alreadyLinked: preview.filter((x: any) => x.existingLedgerEntryId != null).length,
    };
    return reply({
      success: true, databaseChanged: false, summary, transactions: preview,
      message: "Read-only historical linking preview. No ledger links, charges, payments, allocations, or transaction statuses were changed.",
    });
  } catch (error) {
    return reply({ error: error instanceof Error ? error.message : "Historical link preview failed.", databaseChanged: false }, 502);
  }
});
