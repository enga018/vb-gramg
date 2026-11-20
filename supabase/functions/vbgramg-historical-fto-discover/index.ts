import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const HOST="mnregaweb4.dord.gov.in";
const DETAIL_PATH="/netnrega/fto/fto_trasction_dtl.aspx";
const cors={"Access-Control-Allow-Origin":"https://enga018.github.io","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Access-Control-Max-Age":"86400","Content-Type":"application/json"};
function reply(body:Record<string,unknown>,status=200){return new Response(JSON.stringify(body),{status,headers:{...cors,"Cache-Control":"no-store"}});}
function decode(v:string){return v.replace(/&amp;/gi,"&").replace(/&quot;/gi,'"').replace(/&#39;/gi,"'").replace(/&nbsp;/gi," ").replace(/&#(\d+);?/g,(_,n)=>String.fromCodePoint(Number(n))).replace(/&#x([0-9a-f]+);?/gi,(_,n)=>String.fromCodePoint(parseInt(n,16)));}
function textOf(v:string){return decode(v.replace(/<script\b[\s\S]*?<\/script>/gi," ").replace(/<style\b[\s\S]*?<\/style>/gi," ").replace(/<br\s*\/?\s*>/gi," ").replace(/<[^>]*>/g," ")).replace(/[\u00a0\u200b]/g," ").replace(/\s+/g," ").trim();}
function rowsOf(html:string){return [...html.matchAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi)].map(m=>[...m[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c=>textOf(c[1]))).filter(r=>r.some(Boolean));}
function card(v:string){return (String(v||"").match(/\bMZ-\d{2}-(?:\d{3}-){2,3}\d{3}\/\d+(?:-[A-Z]+)?\b/i)?.[0]||"").toUpperCase().replace(/\s+/g,"");}
function parse(html:string,fto:string){
 const rs=rowsOf(html),page=textOf(html),head=rs.find(r=>r.some(c=>/job\s*card\s*no/i.test(c))&&r.some(c=>/reference\s*no/i.test(c)));
 if(!head||!/FTO\s+Transaction\s+Details/i.test(page))throw new Error("Unexpected Government transaction layout.");
 const norm=(s:string)=>s.toLowerCase().replace(/[^a-z0-9]+/g," ").trim(),names=head.map(norm),col=(...v:string[])=>names.findIndex(n=>v.includes(n));
 const j=col("job card no panchayat name","job card no","job card number"),ref=col("reference no","reference number"),status=col("status"),credit=col("credit amount in rs","credit amount");
 const applicant=col("applicant name","name of applicant","name of person"),primary=col("name of primary account holder"),date=col("transaction date"),amount=col("amount to be credited in rs","amount to be credited");
 if([j,ref,status,credit].some(x=>x<0))throw new Error("Government transaction table is missing required columns.");
 const out=[];
 for(const r of rs.slice(rs.indexOf(head)+1)){const jc=card(r[j]||""),reference=(r[ref]||"").trim();if(!jc||!reference)continue;
  const raw=(r[status]||"").trim(),num=(v:string)=>{const x=String(v||"").replace(/[₹,\s]/g,"");return /^\d+(?:\.\d+)?$/.test(x)?Number(x):null;};
  out.push({jobCardNumber:jc,referenceNumber:reference,applicantName:(r[applicant>=0?applicant:primary]||"").trim(),governmentStatus:raw||"blank",transactionDate:date>=0?(r[date]||""):"",creditAmount:num(r[credit]||""),amountToBeCredited:amount>=0?num(r[amount]||""):null,ftoNumber:fto});
 }
 return out;
}
async function manifest(token:string,key:string){
 if(!/^[A-Za-z0-9_-]+$/.test(token)||token.length>2_000_000)throw new Error("Invalid manifest token.");
 const b=token.replace(/-/g,"+").replace(/_/g,"/")+"=".repeat((4-token.length%4)%4),bytes=Uint8Array.from(atob(b),c=>c.charCodeAt(0));
 const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode("VBGRAMG-HISTORICAL-FTOS-v1:"+key)),k=await crypto.subtle.importKey("raw",d,{name:"AES-GCM"},false,["decrypt"]);
 const clear=await crypto.subtle.decrypt({name:"AES-GCM",iv:bytes.slice(0,12)},k,bytes.slice(12)),m=JSON.parse(new TextDecoder().decode(clear));
 if(m?.v!==1||m.exp<Date.now()||!Array.isArray(m.candidates)||m.candidates.length!==975)throw new Error("Manifest expired or invalid. Fetch the Government listing again.");
 return m.candidates as {detailUrl:string;ftoNumber:string;listingRow:string[];listingIndex:number}[];
}
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});if(req.method!=="POST")return reply({error:"Method not allowed."},405);
 const bearer=(req.headers.get("Authorization")||"").replace(/^Bearer\s+/i,"");if(!bearer)return reply({error:"Sign in required."},401);
 const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");if(!url||!anon||!service)return reply({error:"Server configuration incomplete."},500);
 const auth=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}}),{data:claimsData,error:claimsError}=await auth.auth.getClaims(bearer),claims=claimsData?.claims;
 if(claimsError||!claims||typeof claims.sub!=="string"||typeof claims.email!=="string"||claims.app_metadata?.email_verified!==true)return reply({error:"Verified account required."},401);
 const admin=createClient(url,service,{auth:{persistSession:false,autoRefreshToken:false}}),{data:approved,error:accessError}=await admin.from("vbgramg_approved_users").select("role").eq("email",claims.email.trim().toLowerCase()).maybeSingle();
 if(accessError)return reply({error:"Could not verify app access."},500);if(approved?.role!=="admin")return reply({error:"Approved administrator access required."},403);
 try{
  const body=await req.json(),token=body.manifestToken,periodId=body.periodId,start=Number(body.startIndex),size=Number(body.batchSize||25);
  if(typeof token!=="string"||typeof periodId!=="string"||!Number.isInteger(start)||start<0||!Number.isInteger(size)||size<1||size>25)return reply({error:"Provide manifestToken, periodId, startIndex and batchSize (1–25)."},400);
  const candidates=await manifest(token,service),{data:period,error:periodError}=await admin.from("vbgramg_periods").select("id,period_name").eq("id",periodId).maybeSingle();
  if(periodError||!period)return reply({error:"Selected contribution period was not found."},404);
  const {data:charges,error:chargeError}=await admin.from("vbgramg_charge_ledger").select("job_card_number").eq("entry_type","charge").eq("is_voided",false).eq("period_id",periodId);
  if(chargeError)return reply({error:"Could not read selected period Charge Ledger."},500);
  const charged=new Set((charges||[]).map((x:any)=>String(x.job_card_number||"").toUpperCase().replace(/\s+/g,"")).filter(Boolean));
  if(!charged.size)return reply({error:"Selected period has no active Charge Ledger entries."},409);
  const slice=candidates.slice(start,start+size);
  const results=[];
  for(let i=0;i<slice.length;i+=5){
   const group=slice.slice(i,i+5);
   const rows=await Promise.all(group.map(async c=>{
    const u=new URL(c.detailUrl);if(u.protocol!=="https:"||u.hostname!==HOST||u.pathname.toLowerCase()!==DETAIL_PATH||!u.searchParams.has("payload"))throw new Error("Invalid official Government detail URL.");
    const response=await fetch(u.toString(),{redirect:"follow",headers:{"User-Agent":"VBGRAMG-Historical-FTO-Discovery/1.0","Accept":"text/html,application/xhtml+xml","Cache-Control":"no-cache"},signal:AbortSignal.timeout(15000)});
    if(!response.ok||new URL(response.url).hostname!==HOST)throw new Error("Government detail fetch failed for "+c.ftoNumber+".");
    const tx=parse(await response.text(),c.ftoNumber),matches=tx.filter(t=>charged.has(t.jobCardNumber));
    return {ftoNumber:c.ftoNumber,listingIndex:c.listingIndex,listingRow:c.listingRow,governmentTransactionCount:tx.length,matchingTransactionCount:matches.length,matchingJobCardCount:new Set(matches.map(t=>t.jobCardNumber)).size,matches};
   }));
   results.push(...rows);
  }
  return reply({success:true,databaseChanged:false,periodName:period.period_name,periodId,periodChargeRows:charges.length,periodJobCardCount:charged.size,startIndex:start,batchCount:slice.length,totalCandidates:candidates.length,results:results.filter(x=>x.matchingTransactionCount>0),checkedFtoCount:results.length});
 }catch(e){return reply({error:e instanceof Error?e.message:"Period-specific FTO discovery failed.",databaseChanged:false},502);}
});
