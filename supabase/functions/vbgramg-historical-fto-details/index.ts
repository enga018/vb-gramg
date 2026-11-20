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
function decodeHtml(value: string) {
  return value.replace(/&amp;/gi, "&").replace(/&quot;/gi, '"').replace(/&#39;/gi, "'")
    .replace(/&nbsp;/gi, " ").replace(/&#(\d+);?/g, (_, n) => String.fromCodePoint(Number(n)))
    .replace(/&#x([0-9a-f]+);?/gi, (_, n) => String.fromCodePoint(parseInt(n, 16)));
}
function textOf(value: string) {
  return decodeHtml(value.replace(/<script\b[\s\S]*?<\/script>/gi, " ").replace(/<style\b[\s\S]*?<\/style>/gi, " ")
    .replace(/<br\s*\/?\s*>/gi, " ").replace(/<[^>]*>/g, " "))
    .replace(/[\u00a0\u200b]/g, " ").replace(/\s+/g, " ").trim();
}
function rowsOf(html: string) {
  return [...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)]
    .map(m => [...m[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c => textOf(c[1])))
    .filter(row => row.some(Boolean));
}
function normalizeCard(value: unknown) { return String(value || "").trim().toUpperCase().replace(/\s+/g, ""); }
function parseDate(value: string) {
  const m = String(value || "").trim().match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})$/);
  return m ? `${m[3]}-${m[2].padStart(2,"0")}-${m[1].padStart(2,"0")}` : (/^\d{4}-\d{2}-\d{2}$/.test(value) ? value : "");
}
function parseAmount(value: string) {
  const raw = String(value || "").trim().replace(/[₹,\s]/g, "");
  return /^\d+(?:\.\d+)?$/.test(raw) ? Number(raw) : null;
}
function extractCard(value: string) {
  return (String(value || "").match(/\bMZ-\d{2}-(?:\d{3}-){2,3}\d{3}\/\d+(?:-[A-Z]+)?\b/i)?.[0] || "").toUpperCase();
}
function normalizeStatus(value: string) {
  const raw = String(value || "").trim();
  return !raw ? "blank" : /^processed$/i.test(raw) ? "processed" : /^rejected$/i.test(raw) ? "rejected" : "other";
}
function parseDetail(html: string, ftoNumber: string) {
  const tableRows = rowsOf(html), pageText = textOf(html);
  const header = tableRows.find(row => row.some(c => /job\s*card\s*no/i.test(c)) && row.some(c => /reference\s*no/i.test(c)));
  if (!header || !/FTO\s+Transaction\s+Details/i.test(pageText)) throw new Error("Government detail page did not match the expected transaction layout.");
  const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  const names = header.map(norm);
  const col = (...labels: string[]) => names.findIndex(n => labels.includes(n));
  const job = col("job card no panchayat name", "job card no", "job card number");
  const ref = col("reference no", "reference number");
  const date = col("transaction date");
  const applicant = col("applicant name", "name of applicant", "name of person");
  const primary = col("name of primary account holder");
  const credit = col("credit amount in rs", "credit amount");
  const amount = col("amount to be credited in rs", "amount to be credited");
  const status = col("status"), processed = col("processed date"), rejection = col("rejection reason");
  if ([job,ref,credit,status].some(i => i < 0)) throw new Error("Government detail table is missing required columns.");
  const start = tableRows.indexOf(header) + 1;
  const transactions = [];
  for (const row of tableRows.slice(start)) {
    const jobCell = row[job] || "", jobCardNumber = extractCard(jobCell), referenceNumber = (row[ref] || "").trim();
    if (!jobCardNumber || !referenceNumber) continue;
    const rawStatus = (row[status] || "").trim();
    transactions.push({
      ftoNumber, jobCardNumber, referenceNumber,
      status: normalizeStatus(rawStatus), governmentStatus: rawStatus || "blank",
      transactionDate: date >= 0 ? parseDate(row[date] || "") : "",
      processedDate: processed >= 0 ? parseDate(row[processed] || "") : "",
      applicantName: (row[applicant >= 0 ? applicant : primary] || "").trim(),
      amountToBeCredited: amount >= 0 ? parseAmount(row[amount] || "") : null,
      creditAmount: parseAmount(row[credit] || ""),
      rejectionReason: rejection >= 0 ? (row[rejection] || "").trim() : "",
      sourceRow: header.map((name, i) => ({ name, value: row[i] || "" })),
    });
  }
  return transactions;
}
async function openManifest(token: string, serviceKey: string) {
  if (!/^[A-Za-z0-9_-]+$/.test(token) || token.length > 2_000_000) throw new Error("Invalid manifest token.");
  const padded = token.replace(/-/g,"+").replace(/_/g,"/") + "=".repeat((4-token.length%4)%4);
  const bytes = Uint8Array.from(atob(padded), c => c.charCodeAt(0));
  if (bytes.length < 29) throw new Error("Manifest token is incomplete.");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode("VBGRAMG-HISTORICAL-FTOS-v1:" + serviceKey));
  const key = await crypto.subtle.importKey("raw", digest, { name:"AES-GCM" }, false, ["decrypt"]);
  const clear = await crypto.subtle.decrypt({ name:"AES-GCM", iv:bytes.slice(0,12) }, key, bytes.slice(12));
  const manifest = JSON.parse(new TextDecoder().decode(clear));
  if (manifest?.v !== 1 || !Number.isFinite(manifest.exp) || manifest.exp < Date.now() ||
      !Array.isArray(manifest.candidates) || manifest.candidates.length !== 975) throw new Error("Manifest expired or invalid. Fetch the listing again.");
  return manifest as { v:number; exp:number; candidates:{detailUrl:string;ftoNumber:string;listingRow:string[];listingHeaders:string[];listingIndex:number}[] };
}
async function loadChargeCards(admin: any) {
  const { data: periods, error: periodError } = await admin.from("vbgramg_periods")
    .select("id,period_name,period_date").gte("period_date","2026-01-01").lt("period_date","2026-07-01");
  if (periodError || !periods?.length) throw new Error("Could not load JAN26–JUN26 charge periods.");
  const periodMap = new Map(periods.map((p: any) => [p.id, p.period_name]));
  const chargesByCard = new Map<string, Set<string>>();
  for (let offset=0; ; offset+=1000) {
    const { data, error } = await admin.from("vbgramg_charge_ledger")
      .select("job_card_number,period_id,charge_period")
      .eq("entry_type","charge").eq("is_voided",false).in("period_id", periods.map((p:any)=>p.id))
      .order("job_card_number",{ascending:true}).order("id",{ascending:true}).range(offset,offset+999);
    if (error) throw new Error("Could not read the historical Charge Ledger.");
    for (const row of data || []) {
      const card = normalizeCard(row.job_card_number);
      if (!card) continue;
      if (!chargesByCard.has(card)) chargesByCard.set(card,new Set());
      const periodName = periodMap.get(row.period_id);
      if (periodName) chargesByCard.get(card)!.add(periodName);
    }
    if (!data || data.length < 1000) break;
  }
  return { chargesByCard, periodNames: periods.map((p:any)=>p.period_name) };
}
async function readBody(req: Request) {
  const raw = await req.text();
  if (raw.length > 2_100_000) throw new Error("Request is too large.");
  return JSON.parse(raw);
}
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok",{headers:corsHeaders});
  if (req.method !== "POST") return reply({error:"Method not allowed."},405);
  const bearer = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i,"");
  if (!bearer) return reply({error:"Sign in required."},401);
  const url = Deno.env.get("SUPABASE_URL"), anon = Deno.env.get("SUPABASE_ANON_KEY"), service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) return reply({error:"Server configuration is incomplete."},500);
  const auth = createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:claimsData,error:claimsError} = await auth.auth.getClaims(bearer);
  const claims = claimsData?.claims;
  if (claimsError || !claims || typeof claims.sub!=="string" || typeof claims.email!=="string" || claims.app_metadata?.email_verified!==true)
    return reply({error:"A verified account is required."},401);
  const admin = createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:approved,error:approvedError} = await admin.from("vbgramg_approved_users").select("role")
    .eq("email",claims.email.trim().toLowerCase()).maybeSingle();
  if (approvedError) return reply({error:"Could not verify app access."},500);
  if (approved?.role!=="admin") return reply({error:"Only an approved administrator can run historical FTO checks."},403);
  try {
    const body = await readBody(req);
    if (typeof body.manifestToken!=="string" || !Array.isArray(body.ftoNumbers) || body.ftoNumbers.length<1 || body.ftoNumbers.length>5)
      return reply({error:"Provide a manifest token and between one and five FTO numbers.",databaseChanged:false},400);
    const manifest = await openManifest(body.manifestToken,service);
    const requested = body.ftoNumbers.map((v:unknown)=>String(v||"").trim().toUpperCase());
    if (new Set(requested).size!==requested.length) return reply({error:"Duplicate FTO numbers in batch.",databaseChanged:false},400);
    const candidateMap = new Map(manifest.candidates.map(c=>[String(c.ftoNumber).trim().toUpperCase(),c]));
    const candidates = requested.map(n=>candidateMap.get(n));
    if (candidates.some(c=>!c)) return reply({error:"A requested FTO is not part of this verified listing.",databaseChanged:false},400);
    const {chargesByCard,periodNames} = await loadChargeCards(admin);
    const results = await Promise.all((candidates as NonNullable<typeof candidates[number]>[]).map(async candidate=>{
      const parsed = new URL(candidate.detailUrl);
      if (parsed.protocol!=="https:" || parsed.hostname!==HOST || parsed.pathname.toLowerCase()!==DETAIL_PATH || !parsed.searchParams.has("payload"))
        throw new Error("A manifest detail URL failed official-host validation.");
      const response = await fetch(parsed.toString(),{method:"GET",redirect:"follow",
        headers:{"User-Agent":"VBGRAMG-Historical-FTO-Check/1.0","Accept":"text/html,application/xhtml+xml","Accept-Encoding":"identity","Cache-Control":"no-cache"},
        signal:AbortSignal.timeout(15000)});
      if (!response.ok) throw new Error("Government detail request failed for "+candidate.ftoNumber+" (HTTP "+response.status+").");
      if (new URL(response.url).hostname!==HOST) throw new Error("Government detail page redirected to an unexpected host.");
      const transactions = parseDetail(await response.text(),candidate.ftoNumber);
      const matches = transactions.filter(tx=>chargesByCard.has(normalizeCard(tx.jobCardNumber))).map(tx=>({
        ...tx, chargePeriods:[...(chargesByCard.get(normalizeCard(tx.jobCardNumber))||[])],
      }));
      const unmatchedTransactions = transactions.filter(tx=>!chargesByCard.has(normalizeCard(tx.jobCardNumber))).map(tx=>({
        ...tx, unmatchedReason:"No non-voided Charge Ledger entry for this Job Card in JAN26–JUN26.",
      }));
      return {
        ftoNumber:candidate.ftoNumber, listingIndex:candidate.listingIndex,
        listingRow:candidate.listingRow, listingHeaders:candidate.listingHeaders,
        governmentTransactionCount:transactions.length, matchingTransactionCount:matches.length,
        unmatchedTransactionCount:unmatchedTransactions.length,
        matchingJobCardCount:new Set(matches.map(tx=>tx.jobCardNumber)).size,
        matches, unmatchedTransactions,
      };
    }));
    return reply({
      success:true,databaseChanged:false,matchingBasis:"Charge Ledger entries in JAN26–JUN26 (including MAY26 and MAY26 (2)); voided charges excluded",
      chargePeriods:periodNames,chargeJobCardCount:chargesByCard.size,results,
      message:"Read-only historical check completed. No normal FTO import, inspection state, charge, payment, or allocation data was changed.",
    });
  } catch(error) {
    return reply({error:error instanceof Error?error.message:"Historical FTO detail check failed.",databaseChanged:false},502);
  }
});
