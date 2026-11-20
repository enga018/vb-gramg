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
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Cache-Control": "no-store" },
  });
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
  if (claimsError || !claims || typeof claims.sub !== "string" ||
      typeof claims.email !== "string" || claims.app_metadata?.email_verified !== true) {
    return reply({ error: "A verified account is required." }, 401);
  }

  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approved, error: approvedError } = await admin
    .from("vbgramg_approved_users")
    .select("role")
    .eq("email", claims.email.trim().toLowerCase())
    .maybeSingle();

  if (approvedError) return reply({ error: "Could not verify app access." }, 500);
  if (approved?.role !== "admin") return reply({ error: "Only an approved administrator can import historical FTOs." }, 403);

  try {
    const body = await readBody(req);
    if (typeof body.manifestToken !== "string" ||
        !Array.isArray(body.ftoNumbers) ||
        body.ftoNumbers.length < 1 ||
        body.ftoNumbers.length > 5) {
      return reply({ error: "Provide a verified listing token and between one and five FTO numbers.", databaseChanged: false }, 400);
    }

    const requested = body.ftoNumbers.map((value: unknown) => String(value || "").trim().toUpperCase());
    if (requested.some((value: string) => !value) || new Set(requested).size !== requested.length) {
      return reply({ error: "FTO numbers must be non-empty and unique.", databaseChanged: false }, 400);
    }

    // Re-fetch the Government pages through the read-only inspector immediately
    // before import. The inspector validates the signed listing manifest and
    // matches transactions against the JAN26-JUN26 Charge Ledger.
    const inspectionResponse = await fetch(url + "/functions/v1/vbgramg-historical-fto-details", {
      method: "POST",
      headers: {
        "Authorization": "Bearer " + bearer,
        "apikey": anon,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ manifestToken: body.manifestToken, ftoNumbers: requested }),
      signal: AbortSignal.timeout(120_000),
    });

    const inspection = await inspectionResponse.json().catch(() => null);
    if (!inspectionResponse.ok || !inspection?.success || inspection?.databaseChanged !== false ||
        !Array.isArray(inspection.results) || inspection.results.length !== requested.length) {
      return reply({
        error: inspection?.error || "Could not re-verify every selected FTO against the Government source.",
        databaseChanged: false,
      }, 502);
    }

    const ftos = [];
    for (const result of inspection.results) {
      const ftoNumber = String(result.ftoNumber || "").trim().toUpperCase();
      const matches = Array.isArray(result.matches) ? result.matches : [];
      const unmatched = Array.isArray(result.unmatchedTransactions) ? result.unmatchedTransactions : [];
      const governmentCount = Number(result.governmentTransactionCount);

      // Fail closed on incomplete source capture, but preserve verified
      // Government rows that have no surviving historical charge as unlinked
      // FTO audit records.
      if (!requested.includes(ftoNumber) || !Number.isInteger(governmentCount) ||
          governmentCount < 1 || matches.length + unmatched.length !== governmentCount) {
        return reply({
          error: "FTO " + (ftoNumber || "(unknown)") +
            " does not have a complete Government transaction snapshot. No FTOs were imported.",
          databaseChanged: false,
          ftoNumber,
          governmentTransactionCount: governmentCount,
          matchedTransactionCount: matches.length,
          unmatchedTransactionCount: unmatched.length,
        }, 409);
      }

      const rows = [...matches, ...unmatched].map((tx: any) => ({
        ftoNumber: String(tx.ftoNumber || ftoNumber).trim().toUpperCase(),
        jobCardNo: String(tx.jobCardNumber || "").trim(),
        referenceNo: String(tx.referenceNumber || "").trim(),
        personName: String(tx.applicantName || "").trim(),
        villageName: "",
        normalizedStatus: String(tx.status || "").trim().toLowerCase(),
        amountToBeCredited: tx.amountToBeCredited,
        creditAmount: tx.creditAmount,
        transactionDate: tx.transactionDate || null,
        processedDate: tx.processedDate || null,
        rejectionReason: tx.rejectionReason || "",
        sourceRow: tx.sourceRow,
      }));

      if (rows.some((row: any) =>
        !row.jobCardNo || !row.referenceNo || !row.personName ||
        !["processed", "rejected", "blank", "other"].includes(row.normalizedStatus) ||
        !Array.isArray(row.sourceRow) || row.sourceRow.length === 0 ||
        row.amountToBeCredited === null || row.amountToBeCredited === undefined ||
        row.creditAmount === null || row.creditAmount === undefined
      )) {
        return reply({
          error: "FTO " + ftoNumber + " contains an incomplete source transaction. No FTOs were imported.",
          databaseChanged: false,
        }, 422);
      }

      ftos.push({
        ftoNumber,
        governmentTransactionCount: governmentCount,
        rows,
      });
    }

    const { data: imported, error: importError } = await admin.rpc(
      "vbgramg_import_historical_fto_recovery",
      { p_payload: { ftos }, p_actor: claims.sub },
    );

    if (importError) {
      return reply({
        error: importError.message || "Historical FTO import was rejected.",
        databaseChanged: false,
      }, 409);
    }

    return reply({
      success: true,
      databaseChanged: true,
      imported,
      message: "Historical FTO records imported. No Contribution Charge Ledger, payment, allocation, or charge links were created.",
    });
  } catch (error) {
    return reply({
      error: error instanceof Error ? error.message : "Historical FTO import failed.",
      databaseChanged: false,
    }, 502);
  }
});
