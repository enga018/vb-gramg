import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://enga018.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

function reply(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}
function norm(v: unknown) { return String(v ?? "").trim(); }
function sameRow(a: unknown[], b: unknown[], headerA: unknown[], headerB: unknown[]) {
  const fieldsA = new Map<string, string>();
  const fieldsB = new Map<string, string>();
  headerA.forEach((field, i) => {
    const name = norm(field).toLowerCase();
    if (name && !/^sl\.?\s*no\.?$/.test(name)) fieldsA.set(name, norm(a[i]));
  });
  headerB.forEach((field, i) => {
    const name = norm(field).toLowerCase();
    if (name && !/^sl\.?\s*no\.?$/.test(name)) fieldsB.set(name, norm(b[i]));
  });
  const names = new Set([...fieldsA.keys(), ...fieldsB.keys()]);
  for (const name of names) if ((fieldsA.get(name) ?? "") !== (fieldsB.get(name) ?? "")) return false;
  return true;
}
function rowKey(row: unknown[], header: unknown[]) {
  const h = header.map(v => norm(v).toLowerCase());
  const uid = h.findIndex(v => v === "unique id");
  const job = h.findIndex(v => v === "job card number" || v === "jobcard number");
  const applicantNo = h.findIndex(v => v === "applicant no" || v === "applicant no.");
  const name = h.findIndex(v => v === "name of applicant" || v === "applicant name");
  const unique = uid >= 0 ? norm(row[uid]) : "";
  if (unique) return "uid:" + unique;
  const composite = [job >= 0 ? norm(row[job]) : "", applicantNo >= 0 ? norm(row[applicantNo]) : "", name >= 0 ? norm(row[name]) : ""];
  if (composite.every(v => !v)) return "";
  return "fallback:" + composite.join("|").toLocaleLowerCase();
}
function newJobCardSelections(
  oldRows: {row_number:number;row_data:unknown[]}[],
  newRows: {row_number:number;row_data:unknown[]}[],
) {
  const oldHeader = oldRows[0]?.row_data || [];
  const newHeader = newRows[0]?.row_data || [];
  const findIndex = (header: unknown[], names: string[]) =>
    header.findIndex(v => names.includes(norm(v).toLowerCase()));
  const oldJobIndex = findIndex(oldHeader, ["job card number", "jobcard number", "jc no."]);
  const jobIndex = findIndex(newHeader, ["job card number", "jobcard number", "jc no."]);
  const oldApplicantNoIndex = findIndex(oldHeader, ["applicant no", "applicant no."]);
  const oldNameIndex = findIndex(oldHeader, ["name of applicant", "applicant name"]);
  const oldUidIndex = findIndex(oldHeader, ["unique id"]);
  const applicantNoIndex = findIndex(newHeader, ["applicant no", "applicant no."]);
  const nameIndex = findIndex(newHeader, ["name of applicant", "applicant name"]);
  const uidIndex = findIndex(newHeader, ["unique id"]);
  if (jobIndex < 0) throw new Error("The MIS must contain a Job Card Number column to initialise selections.");

  const stableKey = (row: unknown[], jobIndexForRow: number, applicantNoIndexForRow: number, nameIndexForRow: number, uidIndexForRow: number) => {
    const uniqueId = norm(uidIndexForRow >= 0 ? row[uidIndexForRow] : "");
    if (uniqueId) return "uid:" + uniqueId.toLocaleLowerCase();
    const jobCard = norm(jobIndexForRow >= 0 ? row[jobIndexForRow] : "");
    const applicantNo = norm(applicantNoIndexForRow >= 0 ? row[applicantNoIndexForRow] : "");
    const applicantName = norm(nameIndexForRow >= 0 ? row[nameIndexForRow] : "");
    return "fallback:" + JSON.stringify([jobCard, applicantNo, applicantName].map(v => v.toLocaleLowerCase()));
  };

  const oldJobCards = new Set<string>();
  const oldApplicantsByCard = new Map<string, Set<string>>();
  for (const item of oldRows.slice(1)) {
    const row = item.row_data;
    if (!row.some(v => norm(v))) continue;
    const jobCard = norm(oldJobIndex >= 0 ? row[oldJobIndex] : "");
    if (!jobCard) continue;
    oldJobCards.add(jobCard);
    const keys = oldApplicantsByCard.get(jobCard) || new Set<string>();
    keys.add(stableKey(row, oldJobIndex, oldApplicantNoIndex, oldNameIndex, oldUidIndex));
    oldApplicantsByCard.set(jobCard, keys);
  }

  const candidatesByCard = new Map<string, { key:string; applicantNo:string; rowNumber:number }[]>();
  const newCardNumbers = new Set<string>();
  for (const item of newRows.slice(1)) {
    const row = item.row_data;
    if (!row.some(v => norm(v))) continue;
    const jobCard = norm(row[jobIndex]);
    if (!jobCard) continue;
    const isNewCard = !oldJobCards.has(jobCard);
    const isNewApplicant = !(oldApplicantsByCard.get(jobCard)?.has(stableKey(row, jobIndex, applicantNoIndex, nameIndex, uidIndex)) ?? false);
    if (!isNewCard && !isNewApplicant) continue;
    const key = stableKey(row, jobIndex, applicantNoIndex, nameIndex, uidIndex);
    const applicantNo = norm(applicantNoIndex >= 0 ? row[applicantNoIndex] : "");
    const candidates = candidatesByCard.get(jobCard) || [];
    candidates.push({ key, applicantNo, rowNumber: item.row_number });
    candidatesByCard.set(jobCard, candidates);
    if (isNewCard) newCardNumbers.add(jobCard);
  }

  const sortApplicants = (candidates: { key:string; applicantNo:string; rowNumber:number }[]) => candidates.sort((a, b) => {
    const aNo = a.applicantNo.trim(), bNo = b.applicantNo.trim();
    if (!aNo && bNo) return 1;
    if (aNo && !bNo) return -1;
    if (aNo && bNo) {
      const aNumeric = Number(aNo), bNumeric = Number(bNo);
      if (Number.isFinite(aNumeric) && Number.isFinite(bNumeric) && aNumeric !== bNumeric) return aNumeric - bNumeric;
      const natural = aNo.localeCompare(bNo, undefined, { numeric: true, sensitivity: "base" });
      if (natural !== 0) return natural;
    }
    return a.rowNumber - b.rowNumber;
  });

  const newJobCardSelections: { job_card_number:string; applicant_key:string }[] = [];
  const existingCardNewApplicantSelections: { job_card_number:string; applicant_key:string }[] = [];
  for (const [jobCard, candidates] of candidatesByCard) {
    const ordered = sortApplicants(candidates);
    if (!ordered.length) continue;
    const selection = { job_card_number: jobCard, applicant_key: ordered[0].key };
    if (newCardNumbers.has(jobCard)) newJobCardSelections.push(selection);
    else existingCardNewApplicantSelections.push(selection);
  }
  return { newJobCardSelections, existingCardNewApplicantSelections };
}

function labelFor(row: unknown[], header: unknown[]) {
  const h = header.map(v => norm(v).toLowerCase());
  const idx = (names: string[]) => h.findIndex(v => names.includes(v));
  const job = idx(["job card number", "jobcard number"]);
  const household = idx(["head of household", "head of household name"]);
  const name = idx(["name of applicant", "applicant name"]);
  const number = idx(["applicant no", "applicant no."]);
  const uid = idx(["unique id"]);
  return {
    uniqueId: uid >= 0 ? norm(row[uid]) : "",
    jobCardNumber: job >= 0 ? norm(row[job]) : "",
    household: household >= 0 ? norm(row[household]) : "",
    applicantName: name >= 0 ? norm(row[name]) : "",
    applicantNo: number >= 0 ? norm(row[number]) : "",
  };
}
async function readImportRows(admin: ReturnType<typeof createClient>, importId: string) {
  const all: { row_number: number; row_data: unknown[] }[] = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await admin.from("vbgramg_mis_rows")
      .select("row_number,row_data").eq("import_id", importId)
      .order("row_number", { ascending: true }).range(offset, offset + 999);
    if (error) throw error;
    const batch = data || [];
    all.push(...batch.map((r: {row_number:number;row_data:unknown[]}) => ({ row_number:r.row_number, row_data:Array.isArray(r.row_data)?r.row_data:[] })));
    if (batch.length < 1000) break;
  }
  return all;
}
function compareRows(oldRows: {row_number:number;row_data:unknown[]}[], newRows: {row_number:number;row_data:unknown[]}[]) {
  const oldHeader = oldRows[0]?.row_data || [];
  const newHeader = newRows[0]?.row_data || [];
  if (!oldHeader.length || !newHeader.length) throw new Error("Both the existing and new MIS must contain a header row.");
  const oldHasUid = oldHeader.some(v => norm(v).toLowerCase() === "unique id");
  const newHasUid = newHeader.some(v => norm(v).toLowerCase() === "unique id");
  if (!oldHasUid || !newHasUid) throw new Error("Comparison requires a 'Unique ID' column in both the existing and new MIS files. Nothing was changed.");
  const makeMap = (rows: {row_number:number;row_data:unknown[]}[], header: unknown[]) => {
    const map = new Map<string, {row_number:number;row_data:unknown[]}>();
    for (const item of rows.slice(1)) {
      if (!item.row_data.some(v => norm(v))) continue;
      const key = rowKey(item.row_data, header);
      if (!key) throw new Error("A non-empty applicant row has no Unique ID and cannot be safely compared. Nothing was changed.");
      if (map.has(key)) throw new Error("Duplicate applicant identifier detected (" + key.replace(/^uid:/, "") + "). Fix duplicates before importing. Nothing was changed.");
      map.set(key, item);
    }
    return map;
  };
  const oldMap = makeMap(oldRows, oldHeader), newMap = makeMap(newRows, newHeader);
  const added: Record<string,unknown>[] = [], deleted: Record<string,unknown>[] = [], updated: Record<string,unknown>[] = [];
  for (const [key, item] of newMap) {
    const old = oldMap.get(key);
    if (!old) added.push(labelFor(item.row_data, newHeader));
    else if (!sameRow(old.row_data, item.row_data, oldHeader, newHeader)) updated.push({ before: labelFor(old.row_data, oldHeader), after: labelFor(item.row_data, newHeader) });
  }
  for (const [key, item] of oldMap) if (!newMap.has(key)) deleted.push(labelFor(item.row_data, oldHeader));
  return { added, deleted, updated, unchanged: Math.max(0, newMap.size - added.length - updated.length), oldCount: oldMap.size, newCount: newMap.size };
}


const OFFICIAL_REPORT_URL = "https://vbgramgrep.dord.gov.in/VBGRAMG/writereaddata/citizen_out/panchregpeople_2207001005_eng2627.html";
function decodeHtml(s:string){return s.replace(/&#(\d+);?/g,(_,n)=>String.fromCodePoint(Number(n))).replace(/&#x([0-9a-f]+);?/gi,(_,n)=>String.fromCodePoint(parseInt(n,16))).replace(/&nbsp;/gi," ").replace(/&amp;/gi,"&").replace(/&lt;/gi,"<").replace(/&gt;/gi,">").replace(/&quot;/gi,'"').replace(/&apos;/gi,"'").replace(/&#39;/gi,"'");}
function cellText(s:string){return decodeHtml(s.replace(/<!--[\s\S]*?-->/g," ").replace(/<br\s*\/?>/gi," ").replace(/<script\b[\s\S]*?<\/script>/gi," ").replace(/<style\b[\s\S]*?<\/style>/gi," ").replace(/<[^>]*>/g," ")).replace(/[\u00a0\u200b]/g," ").replace(/\s+/g," ").trim();}
function parseHtmlRows(table:string){const rowBlocks=[...table.matchAll(/<tr\b[^>]*>([\s\S]*?)(?=<tr\b|$)/gi)];return rowBlocks.map(m=>[...m[1].matchAll(/<t[dh]\b[^>]*>([\s\S]*?)<\/t[dh]>/gi)].map(c=>cellText(c[1]))).filter(r=>r.some(Boolean));}
function hkey(v:unknown){return norm(v).toLowerCase().replace(/&/g," and ").replace(/[^a-z0-9]+/g," ").replace(/\s+/g," ").trim();}
function col(header:unknown[],aliases:string[]){const keys=header.map(hkey);let i=keys.findIndex(k=>aliases.includes(k));return i>=0?i:keys.findIndex(k=>aliases.some(a=>k.includes(a)||a.includes(k)));}
function cleanApplicant(v:unknown){return norm(v).replace(/\*/g,"").normalize("NFKC").toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu," ").trim();}
async function buildOfficialRows(html:string,admin:ReturnType<typeof createClient>){
 if(new TextEncoder().encode(html).length>8_000_000||!html.toLowerCase().includes("registration application register")||!/NEW\s*SERCHHIP\s*North/i.test(html))throw new Error("Official report or village validation failed.");
 const tables=[...html.matchAll(/<table\b[^>]*>([\s\S]*?)<\/table>/gi)].map(m=>m[1]);
 const parsedTables=tables.map((table,index)=>({index,table,rows:parseHtmlRows(table)}));
 const label=(v:unknown)=>hkey(v).replace(/\bno\b/g,"number");
 const headerAliases=[
  ["sl no","s no"],["head of household","head of household name"],["caste"],
  ["name of applicant","applicant name"],["father husband name","father name","husband name"],
  ["gender","sex"],["age"],["date of receipt of application request for registration","date of receipt of application"],
  ["job card number","jobcard number"],["job card issue date"],
  ["reasons if job card not issued any other remarks","reasons if job card not issued","remarks"],
  ["disabled"],["minority"],["job card verified on date"]
 ];
 const headerScore=(row:string[])=>{
  const keys=row.map(label);
  const matches=headerAliases.filter(aliases=>keys.some(key=>aliases.some(alias=>key===alias||key.includes(alias)))).length;
  const hasJob=keys.some(key=>key.includes("job card number")||key.includes("jobcard number"));
  const hasName=keys.some(key=>key.includes("name of applicant")||key.includes("applicant name"));
  const hasHouse=keys.some(key=>key.includes("head of household"));
  return {matches,hasJob,hasName,hasHouse};
 };
 let sourceHeader:string[]=[];
 let headerTableIndex=-1;
 let headerEndRow=-1;
 for(const candidate of parsedTables){
  const rows=candidate.rows;
  for(let i=0;i<Math.min(rows.length,12);i++){
   for(let span=1;span<=3&&i+span<=rows.length;span++){
    const win=rows.slice(i,i+span),width=Math.max(...win.map(row=>row.length));
    const merged=Array.from({length:width},(_,column)=>{
     for(const row of win){const value=norm(row[column]);if(value&&!/^\d+$/.test(value))return value;}
     return "";
    });
    const score=headerScore(merged);
    if(score.matches>=6&&score.hasJob&&score.hasName&&score.hasHouse){
     sourceHeader=merged;headerTableIndex=candidate.index;headerEndRow=i+span-1;break;
    }
   }
   if(headerTableIndex>=0)break;
  }
  if(headerTableIndex>=0)break;
 }
 const dataCandidates=parsedTables.filter(candidate=>candidate.rows.length>100);
 const selectedData=dataCandidates.sort((a,b)=>b.rows.length-a.rows.length)[0];
 const table=selectedData?.table||"";
 const rows=selectedData?.rows||[];
 if(!table){const diagnostics={htmlBytes:new TextEncoder().encode(html).length,tableCount:tables.length,tableStats:parsedTables.map(x=>({index:x.index,rows:x.rows.length})),hasRegisterTitle:/registration application register/i.test(html),hasVillage:/NEW\s*SERCHHIP\s*North/i.test(html)};console.error("Official MIS table diagnostics",JSON.stringify(diagnostics));throw new Error("Could not identify the official applicant register table. HTML bytes: "+diagnostics.htmlBytes+"; tables: "+tables.length+".");}
 if(rows.length<2){const diagnostics={htmlBytes:new TextEncoder().encode(html).length,tableCount:tables.length,selectedTable:selectedData?.index??-1,selectedRows:rows.length};console.error("Official MIS incomplete HTML diagnostics",JSON.stringify(diagnostics));throw new Error("Official register returned incomplete HTML (selected table rows: "+rows.length+"; HTML bytes: "+diagnostics.htmlBytes+"). No data changed.");}
 let headerAt=-1;
 if(headerTableIndex>=0){
  // Headings are in a separate report table; applicant data starts after the serial-number and village-summary rows.
  headerAt=-1;
 }else{
  const diagnostics={tableStats:parsedTables.map(x=>({index:x.index,rows:x.rows.length})),firstRows:parsedTables.map(x=>({index:x.index,rows:x.rows.slice(0,4).map(row=>row.length)}))};
  console.error("Official MIS header table diagnostics",JSON.stringify(diagnostics));
  throw new Error("Could not identify the official register headings in any report table. No data changed.");
 }
 // The heading table is separate from the large applicant table. The data table begins with
 // a 15-position numbering row and a village/count summary row; applicant records follow.
 headerAt=1;
 const sourceColumnCount=sourceHeader.length;
 if(sourceColumnCount<14||sourceColumnCount>15)throw new Error("Official register heading count is unexpected ("+sourceColumnCount+"). No data changed.");
 if(sourceHeader.length===15&&!norm(sourceHeader[14]))sourceHeader=sourceHeader.slice(0,14);
 const si={
  household:col(sourceHeader,["head of household","head of household name"]),
  caste:col(sourceHeader,["caste"]),
  name:col(sourceHeader,["name of applicant","applicant name"]),
  father:col(sourceHeader,["father husband name","father name","husband name"]),
  gender:col(sourceHeader,["gender"]), age:col(sourceHeader,["age"]),
  receipt:col(sourceHeader,["date of receipt of application request for registration","date of receipt of application"]),
  job:col(sourceHeader,["job card number","jobcard number"]),
  issue:col(sourceHeader,["job card issue date"]),
  remarks:col(sourceHeader,["reasons if job card not issued any other remarks","reasons if job card not issued","remarks"]),
  disabled:col(sourceHeader,["disabled"]), minority:col(sourceHeader,["minority"]),
  verified:col(sourceHeader,["job card verified on date"])
 };
 if([si.household,si.name,si.job].some(i=>i<0))throw new Error("Official register is missing required household, applicant or job-card columns.");
 const {data:state,error:se}=await admin.from("vbgramg_mis_state").select("active_import_id").eq("singleton",true).maybeSingle();if(se)throw se;if(!state?.active_import_id)throw new Error("No active MIS baseline exists.");
 const active=await readImportRows(admin,state.active_import_id),oldHeader=active[0]?.row_data?.map(norm)||[];
 if(!oldHeader.length)throw new Error("Could not read the active MIS header.");
 const serial=oldHeader.findIndex(v=>/^sl\.?\s*no\.?$|^s\.?\s*no\.?$/i.test(v)),targetHeader=oldHeader.filter((_,i)=>i!==serial),old=active.map(x=>x.row_data.filter((_,i)=>i!==serial));
 const ti={
  job:col(targetHeader,["job card number","jobcard number"]), jc:col(targetHeader,["jc no","jc number"]),
  house:col(targetHeader,["head of household","head of household name"]),
  caste:col(targetHeader,["caste"]), name:col(targetHeader,["name of applicant","applicant name"]),
  father:col(targetHeader,["father husband name","father name","husband name"]),
  gender:col(targetHeader,["gender"]), age:col(targetHeader,["age"]),
  receipt:col(targetHeader,["date of receipt of application request for registration","date of receipt of application"]),
  issue:col(targetHeader,["job card issue date"]),
  remarks:col(targetHeader,["reasons if job card not issued any other remarks","reasons if job card not issued","remarks"]),
  disabled:col(targetHeader,["disabled"]), minority:col(targetHeader,["minority"]),
  verified:col(targetHeader,["job card verified on date"]),
  no:col(targetHeader,["applicant no","applicant no."]), uid:col(targetHeader,["unique id"])
 };
 if([ti.job,ti.house,ti.name,ti.no,ti.uid].some(i=>i<0))throw new Error("Active MIS is missing required matching columns.");
 const matches=new Map<string,{no:string;uid:string}[]>(),maxNo=new Map<string,number>();
 for(const r of old.slice(1)){const card=norm(r[ti.job]);if(!card)continue;const nm=cleanApplicant(r[ti.name]),no=norm(r[ti.no]),uid=norm(r[ti.uid]);if(nm){const k=card.toLowerCase()+"|"+nm,a=matches.get(k)||[];a.push({no,uid});matches.set(k,a);}const n=Number(no);if(no&&Number.isFinite(n))maxNo.set(card,Math.max(maxNo.get(card)||0,n));}
 const output:unknown[][]=[targetHeader],used=new Set<string>(),next=new Map<string,number>(),review:string[]=[];let prevCard="",prevHouse="";
 for(let i=headerAt+1;i<rows.length;i++){const r=rows[i],txt=r.map(norm).filter(Boolean).join(" · ");if(!txt)continue;if(/^(villages?\b|no\. of registrants\b|total no\. of registered applicants\b|total\b|report completed\b|# end of report\b)/i.test(txt))continue;
 const card=norm(r[si.job]),name=norm(r[si.name]);if(!/^MZ-/i.test(card)||!card.includes("/")||!name){if(!card&&!name)continue;review.push("Unrecognized source row "+(i+1)+": "+txt);continue;}
 if(card!==prevCard){prevCard=card;prevHouse="";}const rawHouse=norm(r[si.household]);if(rawHouse)prevHouse=rawHouse.replace(/\*/g,"").trim();const house=rawHouse?rawHouse.replace(/\*/g,"").trim():prevHouse;
 const deleted=(rawHouse.includes("*")||name.includes("*")||(si.remarks>=0&&/\bdeleted\b/i.test(norm(r[si.remarks]))));if(deleted)continue;if(!house){review.push("Missing household head at source row "+(i+1));continue;}
 const q=matches.get(card.toLowerCase()+"|"+cleanApplicant(name))||[],match=q.shift();if(match&&!match.uid){review.push("Matched applicant has no Unique ID: "+card+" · "+name);continue;}
 let no=match?.no||"";if(!no){no=String((maxNo.get(card)||0)+(next.get(card)||0)+1);next.set(card,(next.get(card)||0)+1);}
 let uid=match?.uid||"";if(uid&&used.has(uid)){review.push("Duplicate Unique ID: "+uid);continue;}if(!uid)uid=crypto.randomUUID();used.add(uid);
 const out=targetHeader.map(()=>"");
  const copy=(targetIndex:number,sourceIndex:number)=>{if(targetIndex>=0&&sourceIndex>=0)out[targetIndex]=norm(r[sourceIndex]);};
  out[ti.job]=card;if(ti.jc>=0)out[ti.jc]=card.split("/").pop();
  out[ti.house]=house;out[ti.name]=name.replace(/\*/g,"").trim();
  copy(ti.caste,si.caste);copy(ti.father,si.father);copy(ti.gender,si.gender);copy(ti.age,si.age);
  copy(ti.receipt,si.receipt);copy(ti.issue,si.issue);copy(ti.remarks,si.remarks);
  copy(ti.disabled,si.disabled);copy(ti.minority,si.minority);copy(ti.verified,si.verified);
  out[ti.no]=no;out[ti.uid]=uid;output.push(out);
 }
 if(review.length)throw new Error("MIS parsing paused: "+review.length+" uncertain row(s). No data changed. First issue: "+review[0]);
 if(output.length<2||output.length>100001)throw new Error("Parsed applicant count is outside the permitted range.");
 return {output,activeImportId:state.active_import_id,sourceRows:rows.length};
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return reply({ error: "Method not allowed" }, 405);

  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token || token === authHeader) return reply({ error: "Sign in required." }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply({ error: "Server configuration is incomplete." }, 500);

  const authClient = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  if (authError || !authData.user) return reply({ error: "Invalid or expired session. Sign in again." }, 401);
  if (!authData.user.email_confirmed_at) return reply({ error: "A verified email account is required." }, 403);

  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: approval, error: approvalError } = await admin.from("vbgramg_approved_users")
    .select("role").eq("email", (authData.user.email || "").toLowerCase()).maybeSingle();
  if (approvalError) return reply({ error: "Could not verify import permissions." }, 500);
  if (approval?.role !== "admin") return reply({ error: "Administrator approval is required to import MIS." }, 403);

  try {
    const body = await req.json();
    const action = body?.action;


    if (action === "official-fetch") {
      const response = await fetch(OFFICIAL_REPORT_URL, { method:"GET", redirect:"follow", headers:{"User-Agent":"VBGRAMG-MIS-Reader/1.0","Accept":"text/html,application/xhtml+xml","Accept-Encoding":"identity","Cache-Control":"no-cache","Pragma":"no-cache"}, signal:AbortSignal.timeout(30000) });
      if (!response.ok) return reply({error:"Government MIS returned HTTP "+response.status+". No data changed."},502);
      const built = await buildOfficialRows(await response.text(), admin);
      const filename = "Official Registration Application Register — New Serchhip North";
      const {data:record,error:insertError}=await admin.from("vbgramg_mis_imports").insert({source_filename:filename,source_sheet:"MIS",imported_by:authData.user.id,row_count:built.output.length,status:"staging"}).select("id").single();
      if(insertError)throw insertError;
      try {
        for(let offset=0;offset<built.output.length;offset+=250){
          const payload=built.output.slice(offset,offset+250).map((row,index)=>({import_id:record.id,row_number:offset+index+1,row_data:row}));
          const {error}=await admin.from("vbgramg_mis_rows").insert(payload);if(error)throw error;
        }
        const staged=await readImportRows(admin,record.id),oldRows=await readImportRows(admin,built.activeImportId),diff=compareRows(oldRows,staged);
        return reply({success:true,importId:record.id,expectedActiveImportId:built.activeImportId,sourceFilename:filename,sourceRowCount:built.sourceRows,parsedApplicantCount:built.output.length-1,...diff});
      } catch(error) {
        await admin.from("vbgramg_mis_rows").delete().eq("import_id",record.id);
        await admin.from("vbgramg_mis_imports").delete().eq("id",record.id);
        throw error;
      }
    }

    if (action === "prepare") {
      const { data: state, error: stateError } = await admin.from("vbgramg_mis_state").select("active_import_id").eq("singleton", true).maybeSingle();
      if (stateError) throw stateError;
      if (!state?.active_import_id) return reply({ error: "No active MIS is available for matching existing Unique IDs." }, 409);
      const rows = await readImportRows(admin, state.active_import_id);
      return reply({ activeRows: rows.map(item => item.row_data), activeRowCount: Math.max(0, rows.length - 1) });
    }

    if (action === "begin") {
      const filename = typeof body.filename === "string" ? body.filename.slice(0, 255) : "";
      const rowCount = body.rowCount;
      if (!filename || !Number.isInteger(rowCount) || rowCount < 1 || rowCount > 100000) {
        return reply({ error: "Invalid filename or row count (must be 1–100,000 rows). The existing data has not changed." }, 400);
      }
      const { data, error } = await admin.from("vbgramg_mis_imports")
        .insert({ source_filename: filename, source_sheet: "MIS", imported_by: authData.user.id, row_count: rowCount, status: "staging" })
        .select("id").single();
      if (error) throw error;
      return reply({ importId: data.id });
    }

    if (action === "append") {
      const importId = body.importId, startRow = body.startRow, rows = body.rows;
      if (typeof importId !== "string" || !Number.isInteger(startRow) || startRow < 1 ||
          !Array.isArray(rows) || rows.length < 1 || rows.length > 250 ||
          rows.some((row: unknown) => !Array.isArray(row))) return reply({ error: "Invalid row batch." }, 400);
      const { data: record, error: recordError } = await admin.from("vbgramg_mis_imports")
        .select("id,status,row_count,imported_by").eq("id", importId).maybeSingle();
      if (recordError) throw recordError;
      if (!record || record.status !== "staging" || record.imported_by !== authData.user.id) return reply({ error: "Import session not found or not writable." }, 404);
      if (startRow + rows.length - 1 > record.row_count) return reply({ error: "Batch exceeds expected row count." }, 400);
      const payload = rows.map((row: unknown[], index: number) => ({ import_id: importId, row_number: startRow + index, row_data: row }));
      const { error } = await admin.from("vbgramg_mis_rows").insert(payload);
      if (error) throw error;
      return reply({ inserted: rows.length });
    }

    if (action === "compare" || action === "finalize") {
      const importId = body.importId;
      if (typeof importId !== "string") return reply({ error: "Invalid import ID." }, 400);
      const { data: record, error: recordError } = await admin.from("vbgramg_mis_imports")
        .select("id,source_filename,row_count,status,imported_by").eq("id", importId).maybeSingle();
      if (recordError) throw recordError;
      if (!record || record.status !== "staging" || record.imported_by !== authData.user.id) return reply({ error: "Import session not found or not writable." }, 404);
      const { count, error: countError } = await admin.from("vbgramg_mis_rows")
        .select("row_number", { count: "exact", head: true }).eq("import_id", importId);
      if (countError) throw countError;
      if (count !== record.row_count) return reply({ error: `Row count mismatch: expected ${record.row_count}, saved ${count ?? 0}. Existing active data was not changed.` }, 409);
      const { data: state, error: stateError } = await admin.from("vbgramg_mis_state")
        .select("active_import_id,source_filename,row_count").eq("singleton", true).maybeSingle();
      if (stateError) throw stateError;
      if (action === "finalize" && (body.expectedActiveImportId ?? null) !== (state?.active_import_id ?? null)) {
        return reply({ error: "The active MIS changed after comparison. Please compare again. No changes were applied." }, 409);
      }
      const newRows = await readImportRows(admin, importId);
      if (!state?.active_import_id) {
        return reply({ error: "No existing active MIS is available to compare. Please contact the administrator to establish the initial baseline first." }, 409);
      }
      const oldRows = await readImportRows(admin, state.active_import_id);
      const diff = compareRows(oldRows, newRows);
      if (action === "compare") {
        return reply({ success: true, importId, expectedActiveImportId: state.active_import_id, sourceFilename: record.source_filename, ...diff });
      }

      const { error: completeError } = await admin.from("vbgramg_mis_imports")
        .update({ status: "complete", completed_at: new Date().toISOString() }).eq("id", importId);
      if (completeError) throw completeError;
      const syncedAt = new Date().toISOString();
      const { error: stateUpdateError } = await admin.from("vbgramg_mis_state").update({
        active_import_id: importId,
        source_filename: record.source_filename,
        row_count: record.row_count,
        updated_at: syncedAt,
      }).eq("singleton", true);
      if (stateUpdateError) {
        await admin.from("vbgramg_mis_imports").update({ status: "staging", completed_at: null }).eq("id", importId);
        throw stateUpdateError;
      }

      // New job cards get their lowest-numbered applicant selected.
      // Existing job cards are auto-selected only when a new applicant was added AND no selection
      // exists already. Existing marked applicants are never replaced by an import.
      let autoSelectedNewJobCards = 0;
      let autoSelectedNewApplicants = 0;
      let selectionWarning: string | null = null;
      try {
        const selectionCandidates = newJobCardSelections(oldRows, newRows);
        const initialSelections = selectionCandidates.newJobCardSelections;
        if (initialSelections.length) {
          const payload = initialSelections.map(item => ({
            ...item,
            updated_by: "system:auto-new-job-card",
            updated_at: new Date().toISOString(),
          }));
          const { error: selectionError } = await admin.from("vbgramg_mis_selections")
            .upsert(payload, { onConflict: "job_card_number" });
          if (selectionError) throw selectionError;
          autoSelectedNewJobCards = initialSelections.length;
        }

        const addedApplicantCandidates = selectionCandidates.existingCardNewApplicantSelections;
        if (addedApplicantCandidates.length) {
          const { data: savedSelections, error: savedSelectionError } = await admin.from("vbgramg_mis_selections")
            .select("job_card_number")
            .in("job_card_number", addedApplicantCandidates.map(item => item.job_card_number));
          if (savedSelectionError) throw savedSelectionError;
          const alreadyMarked = new Set((savedSelections || []).map(item => item.job_card_number));
          const selectionsToAdd = addedApplicantCandidates.filter(item => !alreadyMarked.has(item.job_card_number));
          if (selectionsToAdd.length) {
            const payload = selectionsToAdd.map(item => ({
              ...item,
              updated_by: "system:auto-new-applicant",
              updated_at: new Date().toISOString(),
            }));
            const { error: selectionError } = await admin.from("vbgramg_mis_selections")
              .upsert(payload, { onConflict: "job_card_number" });
            if (selectionError) throw selectionError;
            autoSelectedNewApplicants = selectionsToAdd.length;
          }
        }
      } catch (error) {
        console.error("Could not initialise MIS applicant selections:", error);
        selectionWarning = "The new MIS is active, but automatic applicant selection could not be completed for some job cards.";
      }

      // The new import is now active. Remove old complete-import row payloads so the database retains
      // only the current MIS records; keep import metadata for a minimal audit trail.
      const { data: oldImports, error: oldImportsError } = await admin.from("vbgramg_mis_imports")
        .select("id").eq("status", "complete").neq("id", importId);
      if (oldImportsError) throw oldImportsError;
      let cleanupWarning: string | null = null;
      for (const oldImport of oldImports || []) {
        const { error: deleteError } = await admin.from("vbgramg_mis_rows").delete().eq("import_id", oldImport.id);
        if (deleteError) {
          console.error("Old MIS row cleanup failed:", deleteError);
          cleanupWarning = "The new MIS is active, but some previous row data could not be cleaned up.";
          break;
        }
      }
      return reply({ success: true, importId, rowCount: count, syncedAt, expectedActiveImportId: state.active_import_id, autoSelectedNewJobCards, autoSelectedNewApplicants, selectionWarning, cleanupWarning, ...diff });
    }

    if (action === "abort") {
      const importId = body.importId;
      if (typeof importId !== "string") return reply({ error: "Invalid import ID." }, 400);
      const { data: record, error } = await admin.from("vbgramg_mis_imports")
        .select("id,status,imported_by").eq("id", importId).maybeSingle();
      if (error) throw error;
      if (record?.status === "staging" && record.imported_by === authData.user.id) await admin.from("vbgramg_mis_imports").delete().eq("id", importId);
      return reply({ success: true });
    }

    return reply({ error: "Unknown action." }, 400);
  } catch (error) {
    console.error("MIS import failure:", error);
    return reply({ error: error instanceof Error ? error.message : "Unexpected import error." }, 500);
  }
});
