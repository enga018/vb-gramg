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
    .replace(/<br\s*\/?\s*>/gi, " ").replace(/<[^>]*>/g, " ")).replace(/[\u00a0\u200b]/g, " ").replace(/\s+/g, " ").trim();
}
function rowsOf(html: string) {
  return [...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)]
    .map(m => [...m[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c => textOf(c[1])))
    .filter(row => row.some(Boolean));
}
function discoverCandidates(html: string, baseUrl: string) {
  const out = new Map<string, { url: string; row: string[] }>();
  for (const table of html.matchAll(/<table\b[^>]*>([\s\S]*?)<\/table>/gi)) {
    const trs = [...table[1].matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)];
    for (const tr of trs) {
      const href = tr[1].match(/<a\b[^>]*href\s*=\s*["']([^"']*fto_trasction_dtl\.aspx\?payload=[^"']+)["']/i)?.[1];
      if (!href) continue;
      const url = new URL(decodeHtml(href), baseUrl);
      if (url.hostname !== "vbgramgrep.dord.gov.in" || url.pathname.toLowerCase() !== "/vbgramg/fto/fto_trasction_dtl.aspx" || !url.searchParams.has("payload")) continue;
      const row = [...tr[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c => textOf(c[1]));
      const number = String(row[3] || "").trim().toUpperCase();
      if (number && !out.has(number)) out.set(number, { url: url.toString(), row });
    }
  }
  return out;
}
function amount(value: string) {
  const raw = String(value || "").trim().replace(/[₹,\s]/g, "");
  if (!/^\d+(?:\.\d+)?$/.test(raw)) return null;
  const n = Number(raw); return Number.isFinite(n) && n >= 0 ? n : null;
}
function parseDate(value: string) {
  const s = String(value || "").trim();
  if (!s) return "";
  const m = s.match(/^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})$/);
  if (m) return `${m[3]}-${m[2].padStart(2,"0")}-${m[1].padStart(2,"0")}`;
  return /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : "";
}
function status(value: string) {
  const s = String(value || "").trim();
  if (!s) return "blank";
  if (/^processed$/i.test(s)) return "processed";
  if (/^rejected$/i.test(s)) return "rejected";
  return "other";
}
function jobCard(value: string) {
  return String(value || "").match(/\bMZ-\d{2}-(?:\d{3}-){2,3}\d{3}\/\d+(?:-[A-Z]+)?\b/i)?.[0].toUpperCase() || "";
}
async function fetchDetail(url: string, ftoNumber: string) {
  const parsed = new URL(url);
  if (parsed.hostname !== "vbgramgrep.dord.gov.in" || parsed.pathname.toLowerCase() !== "/vbgramg/fto/fto_trasction_dtl.aspx" || !parsed.searchParams.has("payload"))
    throw new Error("Government detail URL failed host/path validation.");
  const response = await fetch(url, { redirect: "follow", headers: {
    "User-Agent":"VBGRAMG-FTO-Rechecker/1.0","Accept":"text/html,application/xhtml+xml",
    "Accept-Encoding":"identity","Cache-Control":"no-cache","Pragma":"no-cache"
  }, signal: AbortSignal.timeout(12000) });
  const html = await response.text();
  if (!response.ok) throw new Error("Government detail request failed (HTTP " + response.status + ").");
  if (new URL(response.url).hostname !== "vbgramgrep.dord.gov.in") throw new Error("Government detail redirected to an unexpected host.");
  const allRows = rowsOf(html), pageText = textOf(html);
  if (!/FTO\s+Transaction\s+Details/i.test(pageText)) throw new Error("Government detail page did not validate.");
  const header = allRows.find(r => r.some(c => /job\s*card\s*no/i.test(c)) && r.some(c => /reference\s*no/i.test(c)));
  if (!header) throw new Error("Government transaction table header was not found.");
  const norm = (s:string) => s.toLowerCase().replace(/[^a-z0-9]+/g," ").trim();
  const h = header.map(norm), find = (...names:string[]) => h.findIndex(v => names.includes(v));
  const job=find("job card no panchayat name","job card no","job card number");
  const ref=find("reference no","reference number");
  const credit=find("credit amount in rs","credit amount");
  const state=find("status"), processed=find("processed date"), reason=find("rejection reason");
  if ([job,ref,credit,state].some(v=>v<0)) throw new Error("Government table is missing required columns.");
  const transactions = allRows.slice(allRows.indexOf(header)+1).map((r,i) => {
    const card=jobCard(r[job]||""), reference=String(r[ref]||"").trim();
    const rawStatus=String(r[state]||"").trim();
    return { ftoNumber, jobCardNumber:card, referenceNo:reference, normalizedStatus:status(rawStatus),
      creditAmount:amount(r[credit]||""), processedDate:processed>=0?parseDate(r[processed]||""):"",
      rejectionReason:reason>=0?String(r[reason]||"").trim():"", rowNumber:i+1 };
  });
  if (!transactions.length) throw new Error("Government transaction table is empty.");
  const refs=new Set<string>(), errors:string[]=[];
  for (const tx of transactions) {
    if (!tx.jobCardNumber) errors.push("Government row "+tx.rowNumber+": invalid Job Card Number.");
    if (!tx.referenceNo) errors.push("Government row "+tx.rowNumber+": missing Reference Number.");
    const key=tx.referenceNo.toUpperCase();
    if (key && refs.has(key)) errors.push("Government row "+tx.rowNumber+": duplicate Reference Number "+key+".");
    if (key) refs.add(key);
    if (tx.creditAmount===null) errors.push("Government row "+tx.rowNumber+": invalid Credit Amount.");
    if (tx.normalizedStatus==="other") errors.push("Government row "+tx.rowNumber+": unrecognized status.");
  }
  const listing=(fetchDetail as any).__listingRow as string[]|undefined;
  if (listing) {
    const expectedCount=(i:number)=>{const s=String(listing[i]||"").replace(/,/g,"").trim();return /^\d+$/.test(s)?Number(s):null;};
    const expectedAmount=(i:number)=>amount(listing[i]||"");
    const sum=(xs:any[])=>xs.reduce((n,x)=>n+Number(x.creditAmount||0),0);
    const checks=[
      ["Processed count",expectedCount(8),transactions.filter(x=>x.normalizedStatus==="processed").length],
      ["Rejected count",expectedCount(10),transactions.filter(x=>x.normalizedStatus==="rejected").length],
      ["Processed amount",expectedAmount(9),sum(transactions.filter(x=>x.normalizedStatus==="processed"))],
      ["Rejected amount",expectedAmount(11),sum(transactions.filter(x=>x.normalizedStatus==="rejected"))],
      ["Total amount",expectedAmount(7),sum(transactions)]
    ] as [string,number|null,number][];
    for(const [label,expected,actual] of checks) {
      if(expected===null) errors.push("Government listing "+label+" is missing or invalid.");
      else if(Math.abs(expected-actual)>=0.005) errors.push("Government listing "+label+" does not reconcile with detail rows.");
    }
  }
  if(errors.length) throw new Error(errors.join(" "));
  return transactions;
}
Deno.serve(async (req: Request) => {
  if(req.method==="OPTIONS") return new Response("ok",{headers:corsHeaders});
  if(req.method!=="POST") return reply({error:"Method not allowed."},405);
  const bearer=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");
  if(!bearer) return reply({error:"Sign in required."},401);
  const url=Deno.env.get("SUPABASE_URL"), anon=Deno.env.get("SUPABASE_ANON_KEY"), service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if(!url||!anon||!service) return reply({error:"Server configuration is incomplete."},500);
  const auth=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:claimsData,error:claimsError}=await auth.auth.getClaims(bearer);
  const claims=claimsData?.claims;
  if(claimsError||!claims||typeof claims.sub!=="string"||typeof claims.email!=="string"||claims.app_metadata?.email_verified!==true)
    return reply({error:"A verified account is required."},401);
  const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:approved,error:approvalError}=await admin.from("vbgramg_approved_users").select("email,role")
    .eq("email",claims.email.trim().toLowerCase()).maybeSingle();
  if(approvalError) return reply({error:"Could not verify app access."},500);
  if(!approved||approved.role!=="admin") return reply({error:"Only an approved VBGRAMG administrator can recheck deferred FTOs."},403);
  try {
    const listingResponse=await fetch(LISTING_URL,{redirect:"follow",headers:{
      "User-Agent":"VBGRAMG-FTO-Rechecker/1.0","Accept":"text/html,application/xhtml+xml",
      "Accept-Encoding":"identity","Cache-Control":"no-cache","Pragma":"no-cache"
    },signal:AbortSignal.timeout(20000)});
    const listingHtml=await listingResponse.text();
    if(!listingResponse.ok) throw new Error("Government FTO listing request failed (HTTP "+listingResponse.status+").");
    if(new URL(listingResponse.url).hostname!=="vbgramgrep.dord.gov.in"||!/FTO\s+First\s+Signatory/i.test(textOf(listingHtml)))
      throw new Error("Government listing failed source validation.");
    const candidates=discoverCandidates(listingHtml,listingResponse.url);
    const {data:batches,error:batchError}=await admin.from("vbgramg_fto_batches").select("id,fto_number").order("fto_number");
    if(batchError) throw new Error("Could not load imported FTO history.");
    const batchIds=(batches||[]).map((b:any)=>b.id);
    const deferredByBatch=new Map<string,any[]>();
    for(let offset=0;offset<batchIds.length;offset+=100) {
      const ids=batchIds.slice(offset,offset+100);
      const {data:txs,error:txError}=await admin.from("vbgramg_fto_transactions")
        .select("id,batch_id,reference_no,status").in("batch_id",ids).eq("status","blank");
      if(txError) throw new Error("Could not identify deferred transactions.");
      for(const tx of txs||[]) { const list=deferredByBatch.get(tx.batch_id)||[];list.push(tx);deferredByBatch.set(tx.batch_id,list); }
    }
    const eligible=(batches||[]).filter((b:any)=>(deferredByBatch.get(b.id)||[]).length>0);
    if(!eligible.length) return reply({success:true,ftoCount:0,deferredTransactionCount:0,updatedCount:0,stillDeferredCount:0,failedChecks:[],message:"No imported FTOs currently contain Deferred transactions."});
    const failedChecks:any[]=[], results:any[]=[];
    let updatedCount=0,stillDeferredCount=0;
    for(const batch of eligible) {
      const ftoNumber=String(batch.fto_number||"").trim(), candidate=candidates.get(ftoNumber.toUpperCase());
      try {
        if(!candidate) throw new Error("FTO was not found in the current Government listing.");
        (fetchDetail as any).__listingRow=candidate.row;
        const governmentRows=await fetchDetail(candidate.url,ftoNumber);
        const {data:stored,error:storedError}=await admin.from("vbgramg_fto_transactions")
          .select("reference_no,status").eq("batch_id",batch.id);
        if(storedError) throw new Error("Could not load stored transaction references.");
        const storedByRef=new Map<string,string>();
        for(const item of stored||[]) {
          const key=String(item.reference_no||"").trim().toUpperCase();
          if(!key || storedByRef.has(key)) throw new Error("Stored FTO history contains a missing or duplicate reference number.");
          storedByRef.set(key,String(item.reference_no).trim());
        }
        const governmentByRef=new Map(governmentRows.map(x=>[x.referenceNo.toUpperCase(),x]));
        const missing=[...storedByRef.keys()].filter(x=>!governmentByRef.has(x));
        if(missing.length) throw new Error("Government table is missing stored reference(s): "+missing.slice(0,5).join(", ")+".");
        const payloadRows=[...storedByRef.entries()].map(([key,storedReference])=>{
          const x=governmentByRef.get(key)!;
          return {referenceNo:storedReference,normalizedStatus:x.normalizedStatus,processedDate:x.processedDate,rejectionReason:x.rejectionReason};
        });
        const {data,error}=await admin.rpc("vbgramg_recheck_deferred_ftos",{p_payload:{ftos:[{ftoNumber,rows:payloadRows}]},p_actor:claims.sub});
        if(error) throw new Error(error.message||"Database recheck failed.");
        const resultBatch=data?.batches?.[0]?.result||{};
        updatedCount+=Number(resultBatch.updated_count||0);
        stillDeferredCount+=Number(resultBatch.still_deferred_count||0);
        results.push({ftoNumber,...resultBatch});
      } catch(error) {
        failedChecks.push({ftoNumber,error:error instanceof Error?error.message:"Recheck failed."});
      }
    }
    return reply({success:true,ftoCount:eligible.length,
      deferredTransactionCount:[...deferredByBatch.values()].reduce((n,x)=>n+x.length,0),
      updatedCount,stillDeferredCount,failedCheckCount:failedChecks.length,failedChecks,results,
      message:"Deferred FTO recheck completed. Existing Processed and Rejected records were not changed."});
  } catch(error) {
    return reply({success:false,error:error instanceof Error?error.message:"Deferred FTO recheck failed.",databaseChanged:false},502);
  }
});
