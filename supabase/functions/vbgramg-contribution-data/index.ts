// Payment/refund reconciliation support is deployed through the repository workflow.
import { createClient } from "npm:@supabase/supabase-js@2";
import "../shared/ledger-calculations.js";
const ledgerCalculations = (globalThis as any).VBGRAMGLedgerCalculations;
const corsHeaders={"Access-Control-Allow-Origin":"https://enga018.github.io","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json"};
function reply(body:Record<string,unknown>,status=200){return new Response(JSON.stringify(body),{status,headers:corsHeaders});}
async function recordContributionWrite(admin:any,jobCard:string,operation:string,amount:number|null,entryDate:string,note:string,actorUserId:string,actorEmail:string){
 const {data,error}=await admin.rpc("vbgramg_record_contribution_transaction",{
  p_job_card_number:jobCard,
  p_operation:operation,
  p_amount:amount,
  p_entry_date:entryDate,
  p_note:note,
  p_actor_user_id:actorUserId,
  p_actor_email:actorEmail
 });
 if(error)throw error;
 if(!data||typeof data!=="object")throw new Error("Contribution transaction RPC returned an invalid response.");
 return data as Record<string,any>;
}

function normalizeApplicantName(value:unknown){return String(value||"").normalize("NFKC").replace(/\s+/g," ").trim().toLocaleLowerCase();}
function normalizeApplicantIdentity(value:unknown){return normalizeApplicantName(value).replace(/[^\p{L}\p{N}]+/gu,"");}
async function loadActiveMisApplicants(admin:any){
 const {data:state,error:stateError}=await admin.from("vbgramg_mis_state").select("active_import_id").eq("singleton",true).maybeSingle();
 if(stateError)throw stateError;
 if(!state?.active_import_id)return new Map<string,Record<string,string|null>[]>();
 const records:Record<string,any>[]=[];
 for(let offset=0;;offset+=1000){const {data,error}=await admin.from("vbgramg_mis_rows").select("row_number,row_data").eq("import_id",state.active_import_id).order("row_number",{ascending:true}).range(offset,offset+999);if(error)throw error;records.push(...(data||[]));if(!data||data.length<1000)break;}
 if(!records.length)return new Map<string,Record<string,string|null>[]>();
 const header=Array.isArray(records[0].row_data)?(records[0].row_data as unknown[]).map(v=>String(v||"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim()):[];
 const col=(...names:string[])=>header.findIndex(v=>names.includes(v));
 const jcCol=col("job card number","jobcard number"),nameCol=col("name of applicant","applicant name"),numberCol=col("applicant no","applicant number"),uniqueCol=col("unique id","unique applicant id");
 if(jcCol<0||nameCol<0)throw new Error("The active MIS is missing Job Card Number or Name of Applicant columns.");
 const byCard=new Map<string,Record<string,string|null>[]>();
 for(const record of records.slice(1)){const row=Array.isArray(record.row_data)?record.row_data as unknown[]:[];const jobCard=String(row[jcCol]||"").trim(),name=String(row[nameCol]||"").trim();if(!jobCard||!name)continue;const applicant={applicant_name:name,applicant_number:numberCol>=0?String(row[numberCol]||"").trim()||null:null,applicant_unique_id:uniqueCol>=0?String(row[uniqueCol]||"").trim()||null:null};if(!byCard.has(jobCard))byCard.set(jobCard,[]);byCard.get(jobCard)!.push(applicant);}
 return byCard;
}
function applicantNameScore(left:unknown,right:unknown){
 const a=normalizeApplicantName(left).replace(/[^\p{L}\p{N}]+/gu,""),b=normalizeApplicantName(right).replace(/[^\p{L}\p{N}]+/gu,"");
 if(!a||!b)return 0;
 const prev=Array.from({length:b.length+1},(_,i)=>i);
 for(let i=1;i<=a.length;i++){let diagonal=prev[0];prev[0]=i;for(let j=1;j<=b.length;j++){const above=prev[j];prev[j]=Math.min(prev[j]+1,prev[j-1]+1,diagonal+(a[i-1]===b[j-1]?0:1));diagonal=above;}}
 return Math.round((1-prev[b.length]/Math.max(a.length,b.length))*1000)/10;
}
function rankActiveMisApplicants(byCard:Map<string,Record<string,string|null>[]>,jobCard:string,name:string){
 const applicants=byCard.get(jobCard)||[...(byCard.entries())].find(([card])=>String(card).trim().toUpperCase()===String(jobCard).trim().toUpperCase())?.[1]||[];
 return applicants.map(applicant=>({...applicant,match_percentage:applicantNameScore(name,applicant.applicant_name)})).sort((a,b)=>b.match_percentage-a.match_percentage||String(a.applicant_name).localeCompare(String(b.applicant_name)));
}
function matchActiveMisApplicant(byCard:Map<string,Record<string,string|null>[]>,jobCard:string,name:string){
 const ranked=rankActiveMisApplicants(byCard,jobCard,name);
 return ranked.length===1&&ranked[0].match_percentage>=80?ranked[0]:null;
}
const periodFromNote=(note:string):string|null=>{const n=note.trim().toUpperCase();const months:Record<string,string>={JAN:"01",FEB:"02",MAR:"03",APR:"04",MAY:"05",JUN:"06",JUL:"07",AUG:"08",SEP:"09",OCT:"10",NOV:"11",DEC:"12"};const m=n.match(/^(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\s*26/);return m?`2026-${months[m[1]]}-01`:null;};
const isoDate=(ms:number):string=>new Date(ms).toISOString().slice(0,10);
function ftoEntryDate(rows:any[],deferred:boolean):string|null{if(deferred)return null;const dates=rows.filter(tx=>String(tx.status)==="processed"&&/^\d{4}-\d{2}-\d{2}$/.test(String(tx.processed_date||""))).map(tx=>String(tx.processed_date)).sort();return dates[0]||null;}
async function fetchPagedRowsForJobCard(admin:any,table:string,columns:string,jobCard:string){
 const pageSize=1000;
 const build=(from:number)=>admin.from(table).select(columns).eq("job_card_number",jobCard).order("created_at",{ascending:true}).order("id",{ascending:true}).range(from,from+pageSize-1);
 const rows:Record<string,unknown>[]=[];
 for(let offset=0;;offset+=pageSize){
  const page=await build(offset);
  if(page.error)throw page.error;
  const pageRows=page.data||[];
  rows.push(...pageRows);
  if(pageRows.length<pageSize)break;
 }
 return rows;
}
async function fetchPagedRows(admin:any,table:string,columns:string,orderBy:string,ascending=true,secondaryOrderBy?:string){
 const build=(from:number,to:number)=>{
  let query=admin.from(table).select(columns,{count:"exact"}).order(orderBy,{ascending});
  if(secondaryOrderBy)query=query.order(secondaryOrderBy,{ascending:true});
  query=query.order("id",{ascending:true});
  return query.range(from,to);
 };
 const first=await build(0,999);
 if(first.error)throw first.error;
 if(first.count===null||first.count===undefined)throw new Error(`Could not determine the complete row count for ${table}.`);
 const rows:Record<string,unknown>[]=[...(first.data||[])];
 const total=Number(first.count);
 // Keep no more than four page requests in flight to avoid overwhelming PostgREST.
 for(let base=1000;base<total;base+=4000){
  const offsets:number[]=[];
  for(let offset=base;offset<Math.min(base+4000,total);offset+=1000)offsets.push(offset);
  const pages=await Promise.all(offsets.map(offset=>build(offset,Math.min(offset+999,total-1))));
  for(const page of pages){if(page.error)throw page.error;rows.push(...(page.data||[]));}
 }
 if(rows.length!==total)throw new Error(`Incomplete ${table} read: expected ${total} rows, received ${rows.length}.`);
 return rows;
}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
 const requestStarted=performance.now();
 const header=req.headers.get("Authorization")||"";const token=header.replace(/^Bearer\s+/i,"");
 if(!token||token===header)return reply({error:"Sign in required."},401);
 const url=Deno.env.get("SUPABASE_URL"),anonKey=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
 if(!url||!anonKey||!serviceKey)return reply({error:"Server configuration is incomplete."},500);
 const auth=createClient(url,anonKey,{auth:{persistSession:false,autoRefreshToken:false}});
 const {data:authData,error:authError}=await auth.auth.getUser(token);
 if(authError||!authData.user||!authData.user.email_confirmed_at)return reply({error:"A verified account is required."},401);
 const admin=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
 const email=(authData.user.email||"").trim().toLowerCase();
 const {data:approved,error:approvalError}=await admin.from("vbgramg_approved_users").select("email,role").eq("email",email).maybeSingle();
 if(approvalError)return reply({error:"Could not verify app access."},500);if(!approved)return reply({error:"This account has not been approved for VBGRAMG."},403);
 try{
  const body=await req.json().catch(()=>({}));const action=String(body.action||"list");
  if(action==="save-exemption"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can manage exempt job cards."},403);
   const jobCard=String(body.job_card_number||"").trim().slice(0,100);
   const exempt=body.exempt===true;
   const note=String(body.note||"").trim().slice(0,300);
   if(!jobCard)return reply({error:"Enter a full job card number."},400);
   if(exempt){
    const {error}=await admin.from("vbgramg_contribution_exemptions").upsert({job_card_number:jobCard,note,created_by:authData.user.id,updated_at:new Date().toISOString()},{onConflict:"job_card_number"});
    if(error)throw error;
    // Exemption changes contribution eligibility, not financial history.
    // Keep ledger rows, payments, allocations, extras, citizen metadata, and FTO links intact.
    // The list action and contribution UI suppress balances for exempt cards while retaining
    // the original ledger for audit/history and for a possible later un-exemption.
   }else{
    const {error}=await admin.from("vbgramg_contribution_exemptions").delete().eq("job_card_number",jobCard);
    if(error)throw error;
    // Rebuild formula-generated FTO charges for this card from its retained transaction history.
    const {data:cardTx,error:cardTxError}=await admin.from("vbgramg_fto_transactions").select("id,batch_id,reference_no,job_card_number,person_name,calculated_charge,status,processed_date,is_in_scope").eq("job_card_number",jobCard);
    if(cardTxError)throw cardTxError;
    const batchIds=[...new Set((cardTx||[]).map(tx=>String(tx.batch_id)))];
    const batchPeriods=new Map<string,{month:string,periodId:string}>();
    for(let offset=0;offset<batchIds.length;offset+=500){
     const ids=batchIds.slice(offset,offset+500);
     const {data,error}=await admin.from("vbgramg_fto_batches").select("id,ledger_charge_period,period_id").in("id",ids);
     if(error)throw error;
     for(const b of data||[])batchPeriods.set(String(b.id),{month:String(b.ledger_charge_period||""),periodId:String(b.period_id||"")});
    }
    // Rebuild only against explicit round IDs. Ambiguous legacy batches stay unlinked
    // until an administrator assigns them to the correct round.
    const rounds=[...new Map((cardTx||[]).filter(tx=>tx.is_in_scope===true).map(tx=>{
     const batch=batchPeriods.get(String(tx.batch_id));
     return batch?.periodId? [batch.periodId,{periodId:batch.periodId,month:batch.month}] as const : null;
    }).filter((item):item is readonly [string,{periodId:string,month:string}]=>item!==null)).values()];
    const roundIds=rounds.map(round=>round.periodId);
    if(roundIds.length){
     const {data:ledgerRows,error:ledgerError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,amount,is_deferred,note,reference_numbers,charge_period,period_id").eq("job_card_number",jobCard).eq("entry_type","charge").in("period_id",roundIds);
     if(ledgerError)throw ledgerError;
     for(const round of rounds){
      const period=round.month,periodId=round.periodId;
      const txs=(cardTx||[]).filter(tx=>tx.is_in_scope===true&&batchPeriods.get(String(tx.batch_id))?.periodId===periodId);
      const active=txs.filter(tx=>["blank","processed"].includes(String(tx.status))&&Number(tx.calculated_charge||0)>0);
      const refs=[...new Set(active.map(tx=>String(tx.reference_no)))];
      const amount=Number(active.reduce((sum,tx)=>sum+Number(tx.calculated_charge||0),0).toFixed(2));
      const ftoRows=(ledgerRows||[]).filter(row=>String(row.period_id||"")===periodId&&/^FTO\b/i.test(String(row.note||""))&&!/^FTO EXTRA\b/i.test(String(row.note||"")));
      let keeper=ftoRows.find(row=>(Array.isArray(row.reference_numbers)?row.reference_numbers:[]).some((ref:string)=>refs.includes(String(ref))))||ftoRows[0]||null;
      let ledgerId="";
      if(amount>0){
       const name=String(active[0]?.person_name||keeper?.person_name||"Name needs review");
       const isDeferred=active.every(tx=>String(tx.status)==="blank"),entryDate=ftoEntryDate(active,isDeferred);
       if(keeper){
        const {error}=await admin.from("vbgramg_charge_ledger").update({period_id:periodId,charge_period:period,person_name:name,amount,is_deferred:isDeferred,entry_date:entryDate,reference_numbers:refs,note:"FTO import"}).eq("id",keeper.id);
        if(error)throw error;ledgerId=String(keeper.id);
       }else{
        const {data,error}=await admin.from("vbgramg_charge_ledger").insert({job_card_number:jobCard,person_name:name,entry_type:"charge",amount,charge_period:period,period_id:periodId,entry_date:entryDate,note:"FTO import",reference_numbers:refs,is_deferred:isDeferred,created_by:authData.user.id}).select("id").single();
        if(error)throw error;ledgerId=String(data.id);
       }
       const duplicates=ftoRows.filter(row=>String(row.id)!==ledgerId);
       if(duplicates.length){const {error}=await admin.from("vbgramg_charge_ledger").delete().in("id",duplicates.map(row=>row.id));if(error)throw error;}
       const ids=txs.map(tx=>String(tx.id));
       if(ids.length){const {error}=await admin.from("vbgramg_fto_transactions").update({ledger_entry_id:ledgerId}).in("id",ids);if(error)throw error;}
      }else if(ftoRows.length){
       const {error}=await admin.from("vbgramg_charge_ledger").delete().in("id",ftoRows.map(row=>row.id));if(error)throw error;
       const ids=txs.map(tx=>String(tx.id));
       if(ids.length){const {error}=await admin.from("vbgramg_fto_transactions").update({ledger_entry_id:null}).in("id",ids);if(error)throw error;}
      }
     }
    }
   }
   const {data:exemptions,error:exemptionsError}=await admin.from("vbgramg_contribution_exemptions").select("job_card_number,note,created_at,updated_at").order("job_card_number",{ascending:true});
   if(exemptionsError)throw exemptionsError;
   return reply({approved:true,job_card_number:jobCard,exempt,exemptions:exemptions||[]});
  }

  if(action==="work-demand-balances"){
   const actionStarted=performance.now();
   const requested=Array.isArray(body.job_cards)?[...new Set(body.job_cards.map((value:unknown)=>String(value||"").trim()).filter(Boolean))]:[];
   if(requested.length>5000)return reply({error:"Work Demand can request at most 5,000 job cards."},400);
   if(!requested.length)return reply({approved:true,balances:{},timings_ms:{total:0,database_summary:0,job_cards:0}});
   const summaryStarted=performance.now();
   const {data:summaryResult,error:summaryError}=await admin.rpc("vbgramg_contribution_financial_summary");
   if(summaryError)throw summaryError;
   if(!summaryResult||!Array.isArray(summaryResult.summaries))throw new Error("The database financial summary returned an invalid response.");
   const summaryByCard=new Map((summaryResult.summaries as Record<string,any>[]).map(row=>[String(row.job_card_number||"").trim(),row]));
   const balances:Record<string,number>={};
   for(const id of requested){
    const summary=summaryByCard.get(id);
    if(!summary)throw new Error(`Database financial summary is missing active MIS job card ${id}.`);
    balances[id]=Number(summary.balance)||0;
   }
   const summaryMs=Number((performance.now()-summaryStarted).toFixed(1));
   return reply({approved:true,balances,timings_ms:{database_summary:summaryMs,total:Number((performance.now()-actionStarted).toFixed(1)),job_cards:requested.length}});
  }
  if(action==="job-card-details"){
   const jobCard=String(body.job_card_number||"").trim();
   if(!jobCard||jobCard.length>100)return reply({error:"A valid full job card number is required."},400);
   const detailStarted=performance.now();
   const includePeriods=body.include_periods!==false;
   const queryTimings:Record<string,number>={};
   const timed=async(key:string,request:PromiseLike<any>)=>{
    const started=performance.now();
    try{return await request;}
    finally{queryTimings[key]=Number((performance.now()-started).toFixed(1));}
   };
   const [ledgerRows,extraResult,periodResult,allocationResult,refundResult,financialSummaryResult]=await Promise.all([
    timed("ledger",fetchPagedRowsForJobCard(admin,"vbgramg_charge_ledger","id,job_card_number,applicant_name,applicant_number,applicant_unique_id,entry_type,amount,charge_period,period_id,entry_date,note,created_at,is_deferred,is_voided",jobCard)),
    timed("extras",admin.from("vbgramg_contribution_extras").select("id,job_card_number,person_name,charge_period,period_id,amount,reason,ledger_entry_id,created_at,updated_at").eq("job_card_number",jobCard).order("charge_period",{ascending:false})),
    timed("periods",includePeriods?admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,status,created_at").order("contribution_month",{ascending:false,nullsFirst:false}).order("created_at",{ascending:true}):Promise.resolve({data:[],error:null})),
    timed("allocations",fetchPagedRowsForJobCard(admin,"vbgramg_payment_allocations","id,transaction_id,period_id,job_card_number,amount,allocation_source,confidence,note,created_at,updated_at",jobCard)),
    timed("refunds",fetchPagedRowsForJobCard(admin,"vbgramg_payment_refund_reconciliations","id,payment_id,refund_id,job_card_number,amount,note,created_at",jobCard)),
    timed("financial_summary",admin.rpc("vbgramg_contribution_financial_summary"))
   ]);
   if(extraResult.error)throw extraResult.error;
   if(periodResult.error)throw periodResult.error;
   if(financialSummaryResult.error)throw financialSummaryResult.error;
   const financialSummaries=financialSummaryResult.data?.summaries;
   if(!Array.isArray(financialSummaries))throw new Error("The database financial summary returned an invalid response.");
   const cardSummary=financialSummaries.find((row:any)=>String(row.job_card_number||"").trim()===jobCard);
   if(!cardSummary)throw new Error(`Database financial summary is missing active MIS job card ${jobCard}.`);
   const fifoStarted=performance.now();
   const {data:fifoBreakdown,error:fifoError}=await admin.rpc("vbgramg_contribution_fifo_breakdown",{p_job_card_number:jobCard});
   queryTimings.fifo_breakdown=Number((performance.now()-fifoStarted).toFixed(1));
   if(fifoError)throw fifoError;
   if(!fifoBreakdown||!Array.isArray(fifoBreakdown.groups))throw new Error("Database FIFO breakdown returned an invalid result.");
   const payload={approved:true,job_card_number:jobCard,card_summary:cardSummary,financial_totals:financialSummaryResult.data.totals||{},entries:ledgerRows||[],extras:extraResult.data||[],periods:periodResult.data||[],payment_allocations:allocationResult||[],payment_refund_reconciliations:refundResult||[],fifo_breakdown:fifoBreakdown};
   console.info("[contribution-detail-timing]",JSON.stringify({job_card_number:jobCard,total_ms:Number((performance.now()-detailStarted).toFixed(1)),query_timings_ms:queryTimings,ledger_entries:payload.entries.length,extras:payload.extras.length,periods:payload.periods.length,allocations:payload.payment_allocations.length,refunds:payload.payment_refund_reconciliations.length,periods_included:includePeriods}));
   return reply(payload);
  }

  if(action==="list-summary"){
   const summaryStarted=performance.now();
   const auditCalculations=body.audit_calculations===true;
   if(auditCalculations&&!ledgerCalculations?.calculateLedgerState)throw new Error("Shared ledger calculations are unavailable for audit mode.");
   const [sqlSummaryResult,ledgerResult,exemptionsResult,misStateResult]=await Promise.all([
    admin.rpc("vbgramg_contribution_financial_summary"),
    auditCalculations?admin.rpc("vbgramg_contribution_ledger_list"):Promise.resolve({data:null,error:null}),
    admin.from("vbgramg_contribution_exemptions").select("job_card_number,note,created_at,updated_at").order("job_card_number",{ascending:true}),
    admin.from("vbgramg_mis_state").select("active_import_id,row_count,source_filename").eq("singleton",true).maybeSingle()
   ]);
   if(sqlSummaryResult.error)throw sqlSummaryResult.error;
   if(ledgerResult.error)throw ledgerResult.error;
   if(exemptionsResult.error)throw exemptionsResult.error;
   if(misStateResult.error)throw misStateResult.error;
   const sqlSummary=sqlSummaryResult.data as {summaries?:Record<string,any>[];totals?:Record<string,any>}|null;
   if(!sqlSummary||!Array.isArray(sqlSummary.summaries))throw new Error("The database financial summary returned an invalid response.");
   const ledgerPayload=ledgerResult.data as {entries?:unknown;row_count?:unknown}|null;
   const ledger=Array.isArray(ledgerPayload?.entries)?ledgerPayload.entries as Record<string,any>[]:[];
   if(auditCalculations){
    const ledgerTotal=Number(ledgerPayload?.row_count);
    if(!Number.isInteger(ledgerTotal)||ledgerTotal<0||ledger.length!==ledgerTotal)throw new Error(`Incomplete contribution ledger RPC response: expected ${ledgerTotal} rows, received ${ledger.length}.`);
   }
   const sqlByCard=new Map(sqlSummary.summaries.map(row=>[String(row.job_card_number||"").trim(),row]));
   const misState=misStateResult.data;
   if(!misState?.active_import_id)throw new Error("There is no active MIS import. Load the active MIS before using the contribution table.");
   const {data:lookupCache,error:lookupError}=await admin.from("vbgramg_mis_contribution_lookup").select("payload").eq("import_id",misState.active_import_id).maybeSingle();
   if(lookupError)throw lookupError;
   let citizens:Record<string,string>[]=[];
   let applicantsByCard:Record<string,Record<string,string|null>[]>={};
   if(lookupCache?.payload&&Array.isArray(lookupCache.payload.citizens)&&lookupCache.payload.applicants_by_job_card&&typeof lookupCache.payload.applicants_by_job_card==="object"){
    citizens=lookupCache.payload.citizens;
    applicantsByCard=lookupCache.payload.applicants_by_job_card;
   }else{
    const misRows:Record<string,unknown>[]=[];
    for(let offset=0;;offset+=1000){const {data,error}=await admin.from("vbgramg_mis_rows").select("row_number,row_data").eq("import_id",misState.active_import_id).order("row_number",{ascending:true}).range(offset,offset+999);if(error)throw error;misRows.push(...(data||[]));if(!data||data.length<1000)break;}
    if(!misRows.length)throw new Error("The active MIS import contains no rows.");
    const header=Array.isArray(misRows[0].row_data)?(misRows[0].row_data as unknown[]).map(v=>String(v||"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim()):[];
    const col=(...names:string[])=>header.findIndex(v=>names.includes(v));
    const jcCol=col("job card number","jobcard number"),houseCol=col("head of household","head of household name"),nameCol=col("name of applicant","applicant name"),noCol=col("applicant no","applicant number"),uidCol=col("unique id","unique applicant id");
    if(jcCol<0||nameCol<0)throw new Error("The active MIS is missing Job Card Number or Name of Applicant columns.");
    const householdByCard=new Map<string,string>(),seen=new Set<string>();
    for(const record of misRows.slice(1)){const row=Array.isArray(record.row_data)?record.row_data as unknown[]:[];const card=String(row[jcCol]||"").trim(),name=String(row[nameCol]||"").trim();if(!card||!name)continue;seen.add(card);const household=String(houseCol>=0?row[houseCol]||"":"").trim();if(household&&!householdByCard.has(card))householdByCard.set(card,household);if(!applicantsByCard[card])applicantsByCard[card]=[];applicantsByCard[card].push({applicant_name:name,applicant_number:noCol>=0?String(row[noCol]||"").trim()||null:null,applicant_unique_id:uidCol>=0?String(row[uidCol]||"").trim()||null:null});}
    citizens=[...seen].map(job_card_number=>({job_card_number,person_name:householdByCard.get(job_card_number)||"Household name unavailable"}));
    const {error}=await admin.from("vbgramg_mis_contribution_lookup").upsert({import_id:misState.active_import_id,payload:{citizens,applicants_by_job_card:applicantsByCard},built_at:new Date().toISOString()},{onConflict:"import_id"});
    if(error)throw error;
   }
   const exempted=new Set((exemptionsResult.data||[]).map(row=>String(row.job_card_number||"").trim()));
   const byCard=new Map<string,Record<string,any>[]>();
   if(auditCalculations)for(const row of ledger){const card=String(row.job_card_number||"").trim();if(!card)continue;if(!byCard.has(card))byCard.set(card,[]);byCard.get(card)!.push(row);}
   const auditFlags:Record<string,unknown>[]=[];
   const summaries=citizens.map(c=>{
    const id=String(c.job_card_number||"").trim(),isExempt=exempted.has(id),rows=byCard.get(id)||[];
    const sql=sqlByCard.get(id);
    if(!sql)throw new Error(`Database summary is missing active MIS job card ${id}.`);
    if(auditCalculations){
     const state=ledgerCalculations.calculateLedgerState(rows);
     const jsValues={charges:isExempt?0:state.charged,deferred:isExempt?0:state.deferred,paid:isExempt?0:state.paid,waived:isExempt?0:state.waived,returns:isExempt?0:state.returned,totalCharged:isExempt?0:Math.max(0,state.charged-Math.min(state.charged,state.waived)),balance:isExempt?0:state.balance};
     const sqlValues={charges:Number(sql.charges)||0,deferred:Number(sql.deferred)||0,paid:Number(sql.paid)||0,waived:Number(sql.waived)||0,returns:Number(sql.returns)||0,totalCharged:Number(sql.totalCharged)||0,balance:Number(sql.balance)||0};
     const differences=Object.keys(jsValues).filter(key=>Math.abs(jsValues[key as keyof typeof jsValues]-sqlValues[key as keyof typeof sqlValues])>0.005);
     if(differences.length)auditFlags.push({job_card_number:id,fields:differences,js:jsValues,sql:sqlValues});
    }
    const applicants=Array.isArray(applicantsByCard[id])?applicantsByCard[id]:[];
    const latestApplicant=applicants.slice().sort((a,b)=>String(b.applicant_number||"").localeCompare(String(a.applicant_number||""),undefined,{numeric:true})||String(b.applicant_name||"").localeCompare(String(a.applicant_name||"")))[0];
    return {...sql,job_card_number:id,person_name:String(c.person_name||"Unnamed"),exempt:isExempt,charges:isExempt?0:Number(sql.charges)||0,deferred:isExempt?0:Number(sql.deferred)||0,paid:isExempt?0:Number(sql.paid)||0,waived:isExempt?0:Number(sql.waived)||0,returns:isExempt?0:Number(sql.returns)||0,totalCharged:isExempt?0:Number(sql.totalCharged)||0,balance:isExempt?0:Number(sql.balance)||0,display_applicant:String(latestApplicant?.applicant_name||"").trim()||String(c.person_name||"")};
   });
   const payload={approved:true,role:approved.role,summaries,financial_totals:sqlSummary.totals||{},applicants_by_job_card:applicantsByCard,exemptions:exemptionsResult.data||[],active_mis_import_id:misState.active_import_id,active_mis_row_count:Number(misState.row_count||0),...(auditCalculations?{calculation_audit:{checked_cards:summaries.length,flagged_cards:auditFlags.length,flags:auditFlags}}:{})};
   console.info("[contribution-summary-timing]",JSON.stringify({request_ms:Number((performance.now()-requestStarted).toFixed(1)),total_ms:Number((performance.now()-summaryStarted).toFixed(1)),calculation_source:"postgresql",audit_enabled:auditCalculations,audit_flagged_cards:auditFlags.length,ledger_rows:auditCalculations?ledger.length:0,job_cards:summaries.length,response_bytes:new TextEncoder().encode(JSON.stringify(payload)).length}));
   return reply(payload);
  }

  if(action==="list"){
   const listStarted=performance.now();
   const stageTimes:Record<string,number>={};
   // Independent startup reads run concurrently. The previous sequential requests
   // added each database round-trip to the user's initial loading time.
   const ledgerReadStarted=performance.now();
   const ledgerRequest=admin.rpc("vbgramg_contribution_ledger_list").then(result=>{
    stageTimes.ledger_read_ms=Number((performance.now()-ledgerReadStarted).toFixed(1));
    return result;
   });
   const [ledgerResult,exemptionsResult,misStateResult]=await Promise.all([
    ledgerRequest,
    admin.from("vbgramg_contribution_exemptions").select("job_card_number,note,created_at,updated_at").order("job_card_number",{ascending:true}),
    admin.from("vbgramg_mis_state").select("active_import_id,row_count,source_filename").eq("singleton",true).maybeSingle()
   ]);
   stageTimes.initial_reads_ms=Number((performance.now()-listStarted).toFixed(1));
   if(ledgerResult.error)throw ledgerResult.error;
   if(exemptionsResult.error)throw exemptionsResult.error;
   if(misStateResult.error)throw misStateResult.error;
   const ledgerPayload=ledgerResult.data as {entries?:unknown;row_count?:unknown}|null;
   const all:Record<string,unknown>[]=Array.isArray(ledgerPayload?.entries)?ledgerPayload.entries as Record<string,unknown>[]:[];
   const ledgerTotal=Number(ledgerPayload?.row_count);
   if(!Number.isInteger(ledgerTotal)||ledgerTotal<0||all.length!==ledgerTotal){
    throw new Error(`Incomplete contribution ledger RPC response: expected ${ledgerTotal} rows, received ${all.length}.`);
   }
   const exemptions=exemptionsResult.data||[];
   const misState=misStateResult.data;
   const activeMisRowCount=Number(misState?.row_count||0);
   if(!misState?.active_import_id)throw new Error("There is no active MIS import. Load the active MIS before using the contribution table.");
   // Reuse a versioned lookup built from this exact active MIS import. The cache is
   // immutable per import ID, so a new MIS automatically gets a fresh lookup.
   const misLookupStarted=performance.now();
   const {data:lookupCache,error:lookupCacheError}=await admin.from("vbgramg_mis_contribution_lookup")
    .select("payload").eq("import_id",misState.active_import_id).maybeSingle();
   if(lookupCacheError)throw lookupCacheError;
   let applicantsByCard=new Map<string,Record<string,string|null>[]>();
   let citizens:Record<string,string>[];
   if(lookupCache?.payload&&Array.isArray(lookupCache.payload.citizens)&&lookupCache.payload.applicants_by_job_card&&typeof lookupCache.payload.applicants_by_job_card==="object"){
    citizens=lookupCache.payload.citizens;
    applicantsByCard=new Map(Object.entries(lookupCache.payload.applicants_by_job_card as Record<string,Record<string,string|null>[]>));
   }else{
    const misRows:Record<string,unknown>[]=[];
    for(let offset=0;;offset+=1000){const {data,error}=await admin.from("vbgramg_mis_rows").select("row_number,row_data").eq("import_id",misState.active_import_id).order("row_number",{ascending:true}).range(offset,offset+999);if(error)throw error;misRows.push(...(data||[]));if(!data||data.length<1000)break;}
    if(!misRows.length)throw new Error("The active MIS import contains no rows.");
    const header=Array.isArray(misRows[0].row_data)?(misRows[0].row_data as unknown[]).map(v=>String(v||"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim()):[];
    const col=(...names:string[])=>header.findIndex(v=>names.includes(v));
    const jcCol=col("job card number","jobcard number"),houseCol=col("head of household","head of household name"),nameCol=col("name of applicant","applicant name"),applicantNoCol=col("applicant no","applicant number"),uniqueIdCol=col("unique id","unique applicant id");
    if(jcCol<0||nameCol<0)throw new Error("The active MIS is missing Job Card Number or Name of Applicant columns.");
    const householdByCard=new Map<string,string>(),seenCards=new Set<string>();
    for(const record of misRows.slice(1)){const row=Array.isArray(record.row_data)?record.row_data as unknown[]:[];const jobCard=String(row[jcCol]||"").trim();if(!jobCard)continue;const applicant=String(row[nameCol]||"").trim();if(!applicant)continue;seenCards.add(jobCard);const household=String(houseCol>=0?row[houseCol]||"":"").trim();if(household&&!householdByCard.has(jobCard))householdByCard.set(jobCard,household);const item={applicant_name:applicant,applicant_number:applicantNoCol>=0?String(row[applicantNoCol]||"").trim()||null:null,applicant_unique_id:uniqueIdCol>=0?String(row[uniqueIdCol]||"").trim()||null:null};if(!applicantsByCard.has(jobCard))applicantsByCard.set(jobCard,[]);applicantsByCard.get(jobCard)!.push(item);}
    citizens=[...seenCards].map(job_card_number=>({job_card_number,person_name:householdByCard.get(job_card_number)||"Household name unavailable"}));
    const payload={citizens,applicants_by_job_card:Object.fromEntries(applicantsByCard)};
    const {error:cacheWriteError}=await admin.from("vbgramg_mis_contribution_lookup").upsert({import_id:misState.active_import_id,payload,built_at:new Date().toISOString()},{onConflict:"import_id"});
    if(cacheWriteError)throw cacheWriteError;
   }
   stageTimes.mis_lookup_ms=Number((performance.now()-misLookupStarted).toFixed(1));
   const ftoAttributionStarted=performance.now();
   const chargeEntries=all.filter(r=>r.entry_type==="charge"&&!r.is_voided);
   if(chargeEntries.length){
    const entryById=new Map(chargeEntries.map(entry=>[String(entry.id),entry]));
    // The eligible FTO transaction set is currently small enough for one page.
    // Keep stable, bounded pagination so the lookup remains complete as history grows.
    const txPages:Record<string,unknown>[]=[];
    const pageSize=1000;
    const fetchAttributionPage=async(from:number,to:number,pageNumber:number)=>{
     for(let attempt=0;attempt<3;attempt++){
      let result:{data:any[]|null,error:any};
      try{
       result=await admin.from("vbgramg_fto_transactions").select("id,ledger_entry_id,person_name").not("ledger_entry_id","is",null).gt("calculated_charge",0).in("status",["blank","processed"]).order("id",{ascending:true}).range(from,to);
      }catch(error){
       const message=error instanceof Error?error.message:String(error);
       const transient=/error sending request|fetch failed|network error|connection (?:reset|closed|refused)|temporar(?:y|ily).*unavailable|timed? ?out|aborted/i.test(message);
       if(!transient||attempt===2)throw error;
       console.warn("[contribution-fto-attribution-retry]",{page:pageNumber,attempt:attempt+1,message:message.slice(0,240)});
       await new Promise(resolve=>setTimeout(resolve,250*(attempt+1)));
       continue;
      }
      if(!result.error)return result.data||[];
      const message=String(result.error.message||result.error);
      const transient=/error sending request|fetch failed|network error|connection (?:reset|closed|refused)|temporar(?:y|ily).*unavailable|timed? ?out|aborted/i.test(message);
      if(!transient||attempt===2)throw result.error;
      console.warn("[contribution-fto-attribution-retry]",{page:pageNumber,attempt:attempt+1,message:message.slice(0,240)});
      await new Promise(resolve=>setTimeout(resolve,250*(attempt+1)));
     }
     throw new Error("FTO attribution lookup failed after transient retries.");
    };
    for(let offset=0,pageNumber=1;;offset+=pageSize,pageNumber++){
     const rows=await fetchAttributionPage(offset,offset+pageSize-1,pageNumber);
     txPages.push(...rows);
     if(rows.length<pageSize)break;
    }
    const txNames=new Map<string,Set<string>>();
    for(const tx of txPages){
     const id=String(tx.ledger_entry_id||""),name=String(tx.person_name||"").trim();
     if(!id||!name||!entryById.has(id))continue;
     if(!txNames.has(id))txNames.set(id,new Set());
     txNames.get(id)!.add(name);
    }
    for(const [id,names] of txNames){
     const entry=entryById.get(id);
     if(!entry||names.size!==1)continue;
     const match=matchActiveMisApplicant(applicantsByCard,String(entry.job_card_number),[...names][0]);
     if(match){
      entry.applicant_name=match.applicant_name;
      entry.applicant_number=match.applicant_number;
      entry.applicant_unique_id=match.applicant_unique_id;
      entry.applicant_attribution="matched_from_fto";
     }
    }
   }
   stageTimes.fto_attribution_ms=Number((performance.now()-ftoAttributionStarted).toFixed(1));
   const payload={approved:true,role:approved.role,entries:all,citizens,applicants_by_job_card:Object.fromEntries(applicantsByCard),exemptions:exemptions||[],active_mis_import_id:misState.active_import_id,active_mis_row_count:activeMisRowCount};
   const responseBytes=new TextEncoder().encode(JSON.stringify(payload)).length;
   stageTimes.total_list_ms=Number((performance.now()-listStarted).toFixed(1));
   console.info("[contribution-list-timing]",JSON.stringify({request_ms:Number((performance.now()-requestStarted).toFixed(1)),...stageTimes,ledger_rows:all.length,fto_charge_entries:chargeEntries.length,response_bytes:responseBytes}));
   return reply(payload);
  }
  if(action==="check-fto-duplicates"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can import FTO charges."},403);
   const period=String(body.charge_period||"").trim(),periodId=String(body.period_id||"").trim(),periodMatch=period.match(/^(\d{4})-(\d{2})-01$/);
   if(!periodMatch||Number(periodMatch[2])<1||Number(periodMatch[2])>12)return reply({error:"Choose a valid contribution month."},400);
   const periodDate=period;
   if(action==="check-fto-duplicates"){
    if(!periodId)return reply({error:"Select a specific contribution round."},400);
    const {data:selectedRound,error:selectedRoundError}=await admin.from("vbgramg_periods").select("id,period_name,contribution_month").eq("id",periodId).maybeSingle();
    if(selectedRoundError)throw selectedRoundError;
    if(!selectedRound||String(selectedRound.contribution_month||"")!==periodDate)return reply({error:"The selected contribution round does not match the month."},400);
    const activeMisApplicants=await loadActiveMisApplicants(admin);
    if(!activeMisApplicants.size)return reply({error:"There is no active MIS import available. Import or activate MIS before checking FTO duplicates."},409);
    const activeJobCards=new Set([...activeMisApplicants.keys()].map(card=>String(card).trim().toUpperCase()));
    const {data:exemptionRows,error:exemptionError}=await admin.from("vbgramg_contribution_exemptions").select("job_card_number");
    if(exemptionError)throw exemptionError;
    const exemptedSet=new Set((exemptionRows||[]).map(r=>String(r.job_card_number||"").trim().toUpperCase()));
    const requestedCards=Array.isArray(body.job_cards)?[...new Set(body.job_cards.map((v:unknown)=>String(v||"").trim()).filter(Boolean))]:[];
    const cards=requestedCards.filter(card=>activeJobCards.has(card.toUpperCase()));
    const notInActiveMis=requestedCards.filter(card=>!activeJobCards.has(card.toUpperCase()));
    const referenceRows=Array.isArray(body.reference_rows)?body.reference_rows.map((v:Record<string,unknown>)=>({job_card_number:String(v.job_card_number||"").trim(),person_name:String(v.person_name||"").trim(),reference_numbers:Array.isArray(v.reference_numbers)?[...new Set(v.reference_numbers.map((r:unknown)=>String(r||"").trim()).filter(Boolean))]:[]})).filter(row=>activeJobCards.has(row.job_card_number.toUpperCase())): [];
    if(cards.length>1000)return reply({error:"Check at most 1,000 job cards at a time."},400);
    if(!cards.length)return reply({approved:true,duplicates:[],duplicate_references:[],already_allocated:[],exempted_job_cards:[],unknown_job_cards:[],not_in_active_mis_job_cards:notInActiveMis});
    const {data:existing,error:existingError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,amount,is_deferred,is_voided,note,reference_numbers,period_id,applicant_name,applicant_number,applicant_unique_id,fto_applicant_name").in("job_card_number",cards).eq("entry_type","charge").eq("charge_period",periodDate);
    if(existingError)throw existingError;
    const {data:knownLedger,error:knownLedgerError}=await admin.from("vbgramg_charge_ledger").select("job_card_number").in("job_card_number",cards);
    if(knownLedgerError)throw knownLedgerError;
    const {data:knownCitizens,error:knownCitizensError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number").in("job_card_number",cards);
    if(knownCitizensError)throw knownCitizensError;
    const known=new Set([...(knownLedger||[]).map(r=>String(r.job_card_number).trim().toUpperCase()),...(knownCitizens||[]).map(r=>String(r.job_card_number).trim().toUpperCase())]);
    const allReferences=[...new Set(referenceRows.flatMap(r=>r.reference_numbers))];
    const referenceMatches:Record<string,any>[]=[];
    if(allReferences.length){for(let refOffset=0;refOffset<allReferences.length;refOffset+=100){const refs=allReferences.slice(refOffset,refOffset+100);for(let offset=0;;offset+=1000){const {data,error}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,charge_period,period_id,reference_numbers,amount,is_deferred,is_voided").overlaps("reference_numbers",refs).range(offset,offset+999);if(error)throw error;referenceMatches.push(...(data||[]));if(!data||data.length<1000)break;}}}
    const periodIds=[...new Set(referenceMatches.map(r=>String(r.period_id||"")).filter(Boolean))],periodNames=new Map<string,string>();
    if(periodIds.length){for(let offset=0;offset<periodIds.length;offset+=500){const ids=periodIds.slice(offset,offset+500);const {data,error}=await admin.from("vbgramg_periods").select("id,period_name").in("id",ids);if(error)throw error;for(const p of data||[])periodNames.set(String(p.id),String(p.period_name||""));}}
    const duplicateMap=new Map<string,Set<string>>(),allocatedMap=new Map<string,Map<string,any>>();
    for(const input of referenceRows){for(const reference of input.reference_numbers){for(const old of referenceMatches){if(old.is_voided||!(old.reference_numbers||[]).includes(reference))continue;
      const sameCard=String(old.job_card_number||"").trim().toUpperCase()===input.job_card_number.trim().toUpperCase();
      const sameSelectedPeriod=(old.period_id&&String(old.period_id)===periodId)||(!old.period_id&&String(old.charge_period||"")===periodDate);
      if(sameCard&&sameSelectedPeriod){
       if(!allocatedMap.has(input.job_card_number))allocatedMap.set(input.job_card_number,new Map());
       const ledgerKey=String(old.id||reference);
       if(!allocatedMap.get(input.job_card_number)!.has(ledgerKey))allocatedMap.get(input.job_card_number)!.set(ledgerKey,{reference_numbers:[],period_name:periodNames.get(String(old.period_id||""))||String(selectedRound.period_name||"")||periodDate,amount:Number(old.amount||0),is_deferred:Boolean(old.is_deferred)});
       const allocation=allocatedMap.get(input.job_card_number)!.get(ledgerKey);
       if(!allocation.reference_numbers.includes(reference))allocation.reference_numbers.push(reference);
      }else{if(!duplicateMap.has(input.job_card_number))duplicateMap.set(input.job_card_number,new Set());duplicateMap.get(input.job_card_number)!.add(reference);}
    }}}
    const duplicateRows=[...new Map((existing||[]).filter(r=>!r.is_voided&&(!r.period_id||String(r.period_id)===periodId)&&!exemptedSet.has(String(r.job_card_number||"").trim().toUpperCase())&&!(/^FTO\b/i.test(String(r.note||"")))).map(r=>[r.job_card_number,r])).values()];
    const duplicates=duplicateRows.map(r=>{
     const input=referenceRows.find(item=>item.job_card_number===String(r.job_card_number)),ftoName=String(input?.person_name||"");
     const candidates=rankActiveMisApplicants(activeMisApplicants,String(r.job_card_number),ftoName).slice(0,10);
     const best=candidates[0],second=candidates[1],gap=second?best.match_percentage-second.match_percentage:100;
     const matchConfident=Boolean(best&&best.match_percentage>=80&&(!second||second.match_percentage<80||gap>=10));
     const hasAttachedApplicant=Boolean(r.applicant_unique_id||r.applicant_name||r.applicant_number);
     const applicantMismatch=Boolean(r.applicant_name&&ftoName&&normalizeApplicantIdentity(r.applicant_name)!==normalizeApplicantIdentity(ftoName));
     return {id:r.id,job_card_number:r.job_card_number,person_name:r.person_name,amount:r.amount,is_deferred:r.is_deferred,charge_count:(existing||[]).filter(x=>!x.is_voided&&String(x.job_card_number)===String(r.job_card_number)&&(!x.period_id||String(x.period_id)===periodId)&&!/^FTO\b/i.test(String(x.note||""))).length,applicant_name:r.applicant_name||null,applicant_number:r.applicant_number||null,applicant_unique_id:r.applicant_unique_id||null,fto_applicant_name:r.fto_applicant_name||null,fto_name:ftoName,applicant_mismatch:applicantMismatch,match_confident:matchConfident,suggested_applicant:!hasAttachedApplicant&&matchConfident?best:null,candidates};
    });
    const applicantMatches=referenceRows.map(input=>{const candidates=rankActiveMisApplicants(activeMisApplicants,input.job_card_number,input.person_name).slice(0,10);const best=candidates[0],second=candidates[1];const gap=second?best.match_percentage-second.match_percentage:100;const confident=Boolean(best&&best.match_percentage>=80&&(!second||second.match_percentage<80||gap>=10));return {job_card_number:input.job_card_number,fto_name:input.person_name,candidates,suggested_applicant:confident?best:null,requires_manual:!confident};});
    return reply({approved:true,charge_period:periodDate,duplicates,applicant_matches:applicantMatches,unknown_job_cards:cards.filter(card=>!known.has(card.toUpperCase())&&!exemptedSet.has(card.toUpperCase())),exempted_job_cards:cards.filter(card=>exemptedSet.has(card.toUpperCase())),not_in_active_mis_job_cards:notInActiveMis,already_allocated:[...allocatedMap].map(([job_card_number,refs])=>({job_card_number,allocations:[...refs.values()]})),duplicate_references:[...duplicateMap].map(([job_card_number,refs])=>({job_card_number,reference_numbers:[...refs]}))});
   }
   const rows=body.rows,sourceSha=String(body.source_sha256||"").toLowerCase(),sourceFilename=String(body.source_filename||"").trim().slice(0,255),ftoNumber=String(body.fto_number||"").trim().toUpperCase().slice(0,100);
   const reviewed=Array.isArray(body.reviewed_duplicates)?new Set(body.reviewed_duplicates.map((v:unknown)=>String(v||"").trim())):new Set<string>();
   const reviewedNewCards=Array.isArray(body.reviewed_new_job_cards)?new Set(body.reviewed_new_job_cards.map((v:unknown)=>String(v||"").trim())):new Set<string>();
   if(!/^[a-f0-9]{64}$/.test(sourceSha)||!sourceFilename)return reply({error:"Import batch identity is missing. Reload the preview and try again."},400);
   if(!Array.isArray(rows)||rows.length<1||rows.length>1000)return reply({error:"Import must contain 1–1,000 grouped job cards."},400);
   const normalized:Record<string,unknown>[]=[];
   const seen=new Set<string>();
   let totalAmount=0;
   for(const raw of localInputRows){
    const jobCard=String(raw.job_card_number||"").trim(),personName=String(raw.person_name||"").trim(),amount=Number(raw.amount),isDeferred=Boolean(raw.is_deferred);
    if(!jobCard||!personName||personName.toLowerCase()==="name needs review"||!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"An import row has a missing job card/account-holder name or invalid amount. Nothing was imported."},400);
    if(seen.has(jobCard))return reply({error:"The preview contains a repeated job card. Reload and review the grouped table before importing."},400);
    seen.add(jobCard);totalAmount+=amount;
    normalized.push({job_card_number:jobCard,person_name:personName,entry_type:"charge",amount,charge_period:periodDate,entry_date:new Date().toISOString().slice(0,10),note:("FTO "+(ftoNumber||sourceFilename)).slice(0,200),is_deferred:isDeferred,created_by:authData.user.id});
   }
   const {data:priorImport,error:priorError}=await admin.from("vbgramg_charge_imports").select("id,status,row_count,total_amount").eq("source_sha256",sourceSha).maybeSingle();
   if(priorError)throw priorError;
   if(priorImport&&priorImport.status==="complete")return reply({approved:true,already_imported:true,import_id:priorImport.id,imported:0,rows:priorImport.row_count,total_amount:priorImport.total_amount});
   const {data:existing,error:existingError}=await admin.from("vbgramg_charge_ledger").select("job_card_number,person_name,amount,is_deferred,import_id").in("job_card_number",normalized.map(r=>String(r.job_card_number))).eq("entry_type","charge").eq("charge_period",periodDate);
   if(existingError)throw existingError;
   const duplicates=[...new Map((existing||[]).filter(r=>!priorImport||r.import_id!==priorImport.id).map(r=>[r.job_card_number,{job_card_number:r.job_card_number,person_name:r.person_name,amount:r.amount,is_deferred:r.is_deferred}])).values()];
   const unreviewed=duplicates.filter(r=>!reviewed.has(String(r.job_card_number)));
   if(unreviewed.length)return reply({error:"Duplicate job card(s) already have a charge for this period. Review each flagged row before importing.",duplicates:unreviewed},409);
   const importCards=normalized.map(r=>String(r.job_card_number));
   const {data:knownLedger,error:knownLedgerError}=await admin.from("vbgramg_charge_ledger").select("job_card_number").in("job_card_number",importCards);
   if(knownLedgerError)throw knownLedgerError;
   const {data:knownCitizens,error:knownCitizensError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number").in("job_card_number",importCards);
   if(knownCitizensError)throw knownCitizensError;
   const knownCards=new Set([...(knownLedger||[]).map(r=>String(r.job_card_number)),...(knownCitizens||[]).map(r=>String(r.job_card_number))]);
   const unknownCards=importCards.filter(card=>!knownCards.has(card));
   const unreviewedNew=unknownCards.filter(card=>!reviewedNewCards.has(card));
   if(unreviewedNew.length)return reply({error:"New job card(s) need manual verification before import.",unknown_job_cards:unreviewedNew},409);
   let importId=priorImport?.id;
   if(!importId){
    const {data:created,error:createError}=await admin.from("vbgramg_charge_imports").insert({source_filename:sourceFilename,source_sha256:sourceSha,charge_period:periodDate,row_count:normalized.length,total_amount:totalAmount,status:"staging",imported_by:authData.user.id,notes:ftoNumber?"FTO No. "+ftoNumber:"FTO pasted table"}).select("id").single();
    if(createError)throw createError;
    importId=created.id;
   }else{
    const {error:updateStagingError}=await admin.from("vbgramg_charge_imports").update({status:"staging",row_count:normalized.length,total_amount:totalAmount,notes:ftoNumber?"FTO No. "+ftoNumber:"FTO pasted table"}).eq("id",importId);
    if(updateStagingError)throw updateStagingError;
   }
   const {data:alreadyRows,error:alreadyRowsError}=await admin.from("vbgramg_charge_ledger").select("job_card_number").eq("import_id",importId);
   if(alreadyRowsError)throw alreadyRowsError;
   const alreadyCards=new Set((alreadyRows||[]).map(r=>String(r.job_card_number)));
   const toInsert=normalized.filter(r=>!alreadyCards.has(String(r.job_card_number))).map(r=>({...r,import_id:importId}));
   if(toInsert.length){
    const {error:insertError}=await admin.from("vbgramg_charge_ledger").insert(toInsert);
    if(insertError){await admin.from("vbgramg_charge_imports").update({status:"failed",notes:"FTO import failed: "+String(insertError.message||"database error").slice(0,500)}).eq("id",importId);throw insertError;}
   }
   const {error:completeError}=await admin.from("vbgramg_charge_imports").update({status:"complete",completed_at:new Date().toISOString()}).eq("id",importId);
   if(completeError)throw completeError;
   return reply({approved:true,imported:toInsert.length,rows:normalized.length,total_amount:totalAmount,import_id:importId,already_imported:false});
  }

  
  if(action==="change-fto-period"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can change an FTO period."},403);
   const batchId=String(body.batch_id||"").trim(); let periodId=String(body.period_id||"").trim(); const contributionPeriod=String(body.contribution_period||"").trim().slice(0,100),chargePeriod=String(body.charge_period||"").trim();
   const periodMatch=chargePeriod.match(/^(\d{4})-(\d{2})-01$/);
   if(!batchId)return reply({error:"Select a saved FTO first."},400);
   if(!contributionPeriod||!periodMatch||Number(periodMatch[2])<1||Number(periodMatch[2])>12)return reply({error:"Enter a valid month and year, such as June 2026."},400);
   const monthNames=["JAN","FEB","MAR","APR","MAY","JUN","JUL","AUG","SEP","OCT","NOV","DEC"];
   const expectedLabel=monthNames[Number(periodMatch[2])-1]+periodMatch[1].slice(-2);
   const isRoundLabel=contributionPeriod.toUpperCase().startsWith(expectedLabel+" (")&&/^\(\d+\)$/.test(contributionPeriod.slice(expectedLabel.length).trim());
    if(contributionPeriod.toUpperCase()!==expectedLabel&&!isRoundLabel)return reply({error:"Period name must match the selected contribution month and optional round number, e.g. MAY26 or MAY26 (2)."},400);
   const {data:batch,error:batchError}=await admin.from("vbgramg_fto_batches").select("id,fto_number,contribution_period,ledger_charge_period,period_id").eq("id",batchId).maybeSingle();
   if(batchError)throw batchError;if(!batch)return reply({error:"The selected FTO was not found. Refresh history and try again."},404);
   if(!periodId){
    let {data:legacyPeriod,error:legacyPeriodError}=await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,status").eq("period_name",contributionPeriod).eq("contribution_month",chargePeriod).maybeSingle();
    if(legacyPeriodError)throw legacyPeriodError;
    if(!legacyPeriod)return reply({error:"The selected charge round does not exist in Period Management. Create or select the correct round first."},400);
    periodId=String(legacyPeriod.id);
   }
   const oldPeriod=String(batch.ledger_charge_period||""),oldPeriodId=String(batch.period_id||"");
   const {data:selectedPeriod,error:selectedPeriodError}=await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,status").eq("id",periodId).maybeSingle();
    if(selectedPeriodError)throw selectedPeriodError;
    if(!selectedPeriod||selectedPeriod.contribution_month!==chargePeriod||selectedPeriod.period_name!==contributionPeriod)return reply({error:"Select a shared charge round for the chosen contribution month."},400);
    if(selectedPeriod.status!=="open"&&oldPeriodId!==periodId)return reply({error:"That period is closed. Reopen it before assigning an FTO."},409);
    if(oldPeriod===chargePeriod&&String(batch.contribution_period||"")===contributionPeriod&&oldPeriodId===periodId)return reply({approved:true,unchanged:true,fto_number:batch.fto_number,contribution_period:contributionPeriod,charge_period:chargePeriod,period_id:periodId,transactions_changed:0,job_cards_recalculated:0});
   const roundIds=[...new Set([oldPeriodId,periodId].filter(Boolean))];
   const {data:roundRows,error:roundRowsError}=await admin.from("vbgramg_periods").select("id,contribution_month").in("id",roundIds);
   if(roundRowsError)throw roundRowsError;
   const roundMonthById=new Map<string,string>((roundRows||[]).map((p:Record<string,any>)=>[String(p.id),String(p.contribution_month||"")]));
   if(oldPeriodId&&!roundMonthById.has(oldPeriodId))return reply({error:"The previous charge round is missing from Period Management. Resolve that period before moving this FTO."},409);
   const {data:batchTx,error:batchTxError}=await admin.from("vbgramg_fto_transactions").select("id,job_card_number").eq("batch_id",batchId);
   if(batchTxError)throw batchTxError;
   const cards=[...new Set((batchTx||[]).map(r=>String(r.job_card_number||"")).filter(Boolean))];
   const {error:updateBatchError}=await admin.from("vbgramg_fto_batches").update({period_id:periodId,contribution_period:contributionPeriod,ledger_charge_period:chargePeriod}).eq("id",batchId);
   if(updateBatchError)throw updateBatchError;
   if(!cards.length)return reply({approved:true,fto_number:batch.fto_number,old_period:oldPeriod,new_period:chargePeriod,contribution_period:contributionPeriod,transactions_changed:(batchTx||[]).length,job_cards_recalculated:0});
   const {data:allTx,error:allTxError}=await admin.from("vbgramg_fto_transactions").select("id,batch_id,reference_no,job_card_number,person_name,calculated_charge,status,processed_date,is_in_scope,last_seen_at").in("job_card_number",cards);
   if(allTxError)throw allTxError;
   const allBatchIds=[...new Set((allTx||[]).map(r=>String(r.batch_id)))];
   const batchPeriodMap=new Map<string,{period:string,fto:string,periodId:string}>();
   for(let offset=0;offset<allBatchIds.length;offset+=500){
    const ids=allBatchIds.slice(offset,offset+500);
    const {data,error}=await admin.from("vbgramg_fto_batches").select("id,fto_number,ledger_charge_period,period_id").in("id",ids);
    if(error)throw error;
    for(const b of data||[])batchPeriodMap.set(String(b.id),{period:String(b.ledger_charge_period||""),fto:String(b.fto_number||""),periodId:String(b.period_id||"")});
   }
   const txs=(allTx||[]).filter(tx=>roundIds.includes(batchPeriodMap.get(String(tx.batch_id))?.periodId||""));
   const inScopeTxs=txs.filter(tx=>tx.is_in_scope===true);
   const {data:exemptionRows,error:exemptionError}=await admin.from("vbgramg_contribution_exemptions").select("job_card_number");
   if(exemptionError)throw exemptionError;
   const exemptCards=new Set((exemptionRows||[]).map(r=>String(r.job_card_number)));
   const txByKey=new Map<string,Record<string,any>[]>();
   for(const tx of inScopeTxs){const p=batchPeriodMap.get(String(tx.batch_id))?.periodId||"";const key=String(tx.job_card_number)+"|"+p;if(!txByKey.has(key))txByKey.set(key,[]);txByKey.get(key)!.push(tx);}
   const chargeMonths=[...new Set([...roundMonthById.values()].filter(Boolean))];
   const {data:oldLedger,error:oldLedgerError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,amount,is_deferred,note,reference_numbers,import_id,charge_period,period_id").in("job_card_number",cards).eq("entry_type","charge").in("charge_period",chargeMonths);
   if(oldLedgerError)throw oldLedgerError;
   const ftoLedger=(row:Record<string,any>)=>/^FTO\b/i.test(String(row.note||""))&&!/^FTO EXTRA\b/i.test(String(row.note||""));
   const ftoRows=(oldLedger||[]).filter(ftoLedger),ledgerByKey=new Map<string,Record<string,any>[]>();
   for(const row of ftoRows){const key=String(row.job_card_number)+"|"+String(row.period_id||"");if(!ledgerByKey.has(key))ledgerByKey.set(key,[]);ledgerByKey.get(key)!.push(row);}
   const assignedLedger=new Map<string,string>();let ledgerUpdated=0,ledgerInserted=0,ledgerDeleted=0;
   for(const card of cards)for(const roundId of roundIds){
    if(exemptCards.has(card))continue;
    const key=card+"|"+roundId,period=roundMonthById.get(roundId)||"",txRows=txByKey.get(key)||[];
    const active=txRows.filter(tx=>["blank","processed"].includes(String(tx.status))&&Number(tx.calculated_charge||0)>0);
    const refs=[...new Set(active.map(tx=>String(tx.reference_no)))],amount=Number(active.reduce((sum,tx)=>sum+Number(tx.calculated_charge||0),0).toFixed(2));
    const existing=(ledgerByKey.get(key)||[]).concat(ftoRows.filter(row=>String(row.job_card_number)===card&&!row.period_id&&String(row.charge_period||"")===period&&(Array.isArray(row.reference_numbers)?row.reference_numbers:[]).some((ref:string)=>refs.includes(String(ref))))).filter((row,index,arr)=>arr.findIndex(other=>String(other.id)===String(row.id))===index),keeper=existing.find(row=>(Array.isArray(row.reference_numbers)?row.reference_numbers:[]).some((ref:string)=>refs.includes(String(ref))))||existing[0]||null;
    let ledgerId="";
    if(amount>0){
     const name=String(active[0]?.person_name||keeper?.person_name||"Name needs review"),isDeferred=active.every(tx=>String(tx.status)==="blank"),entryDate=ftoEntryDate(active,isDeferred);
     if(keeper){const {error}=await admin.from("vbgramg_charge_ledger").update({person_name:name,amount,is_deferred:isDeferred,entry_date:entryDate,reference_numbers:refs,note:"FTO import",charge_period:period,period_id:roundId}).eq("id",keeper.id);if(error)throw error;ledgerId=String(keeper.id);ledgerUpdated++;}
     else{const {data,error}=await admin.from("vbgramg_charge_ledger").insert({job_card_number:card,person_name:name,entry_type:"charge",amount,charge_period:period,period_id:roundId,entry_date:entryDate,note:"FTO import",reference_numbers:refs,is_deferred:isDeferred,created_by:authData.user.id}).select("id").single();if(error)throw error;ledgerId=String(data.id);ledgerInserted++;}
     assignedLedger.set(key,ledgerId);
     const extras=existing.filter(row=>String(row.id)!==ledgerId);
     if(extras.length){const {error}=await admin.from("vbgramg_charge_ledger").delete().in("id",extras.map(row=>row.id));if(error)throw error;ledgerDeleted+=extras.length;}
    }else if(existing.length){const {error}=await admin.from("vbgramg_charge_ledger").delete().in("id",existing.map(row=>row.id));if(error)throw error;ledgerDeleted+=existing.length;}
   }
   const affectedTxIds=txs.map(tx=>String(tx.id));
   for(let offset=0;offset<affectedTxIds.length;offset+=500){const ids=affectedTxIds.slice(offset,offset+500);const {error}=await admin.from("vbgramg_fto_transactions").update({ledger_entry_id:null}).in("id",ids);if(error)throw error;}
   for(const [key,ledgerId] of assignedLedger){const ids=(txByKey.get(key)||[]).map(tx=>String(tx.id));if(ids.length){const {error}=await admin.from("vbgramg_fto_transactions").update({ledger_entry_id:ledgerId}).in("id",ids);if(error)throw error;}}
   return reply({approved:true,fto_number:batch.fto_number,old_period:oldPeriod,new_period:chargePeriod,contribution_period:contributionPeriod,transactions_changed:(batchTx||[]).length,job_cards_recalculated:cards.length,ledger_updated:ledgerUpdated,ledger_inserted:ledgerInserted,ledger_deleted:ledgerDeleted});
  }

  if(action==="list-fto-history"){
    if(approved.role!=="admin")return reply({error:"Only an approved administrator can access FTO tracking."},403);
    const {data:batches,error:batchError}=await admin.from("vbgramg_fto_batches").select("id,fto_number,contribution_period,ledger_charge_period,period_id,village_scope,first_imported_at,last_checked_at,created_by,notes").order("last_checked_at",{ascending:false,nullsFirst:false}).order("first_imported_at",{ascending:false});
    if(batchError)throw batchError;
    const batchRows=batches||[];
    if(!batchRows.length)return reply({approved:true,batches:[]});
    const batchIds=batchRows.map((r:Record<string,unknown>)=>String(r.id));
    const transactions:Record<string,any>[]=[];
    for(let i=0;i<batchIds.length;i+=500){
     const ids=batchIds.slice(i,i+500);
     const {data,error}=await admin.from("vbgramg_fto_transactions").select("id,batch_id,reference_no,job_card_number,village_name,person_name,transaction_date,processed_date,amount_to_be_credited,credit_amount,calculated_charge,status,rejection_reason,last_seen_at,source_row,is_in_scope").in("batch_id",ids).order("job_card_number",{ascending:true}).order("reference_no",{ascending:true});
     if(error)throw error;
     transactions.push(...(data||[]));
    }
    const byBatch=new Map<string,Record<string,any>[]>();
    for(const tx of transactions){const id=String(tx.batch_id);if(!byBatch.has(id))byBatch.set(id,[]);byBatch.get(id)!.push(tx);}
    const result=batchRows.map((batch:Record<string,any>)=>{const rows=byBatch.get(String(batch.id))||[];const counts:Record<string,number>={blank:0,processed:0,rejected:0,other:0};for(const tx of rows){const state=String(tx.status||"other");counts[state]=(counts[state]||0)+1;}return {...batch,transaction_count:rows.length,status_counts:counts,transactions:rows};});
    return reply({approved:true,batches:result});
   }

  if(action==="check-fto-import-state"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can check FTO import history."},403);
   const ftoNumber=String(body.fto_number||"").trim().toUpperCase().slice(0,100);
   if(!ftoNumber)return reply({error:"The FTO number could not be detected from the pasted table."},400);
   const {data:batch,error:batchError}=await admin.from("vbgramg_fto_batches").select("id,fto_number,contribution_period,ledger_charge_period,period_id,village_scope,first_imported_at,last_checked_at").eq("fto_number",ftoNumber).maybeSingle();
   if(batchError)throw batchError;
   if(!batch)return reply({approved:true,found:false,batch:null,unchanged:false,changed_count:0});
   const incoming=Array.isArray(body.transactions)?body.transactions:[];
   if(!incoming.length)return reply({approved:true,found:true,batch,unchanged:false,comparison_available:false,changed_count:0});
   const saved:Record<string,any>[]=[];
   for(let offset=0;;offset+=1000){const {data,error}=await admin.from("vbgramg_fto_transactions").select("reference_no,job_card_number,transaction_date,processed_date,amount_to_be_credited,credit_amount,status,rejection_reason,is_in_scope").eq("batch_id",batch.id).range(offset,offset+999);if(error)throw error;saved.push(...(data||[]));if(!data||data.length<1000)break;}
   const iso=(value:unknown)=>{const v=String(value||"").trim();const m=v.match(/^(\d{2})\/(\d{2})\/(\d{4})$/);if(m)return m[3]+"-"+m[2]+"-"+m[1];return /^\d{4}-\d{2}-\d{2}$/.test(v)?v:"";};
   const amount=(value:unknown)=>{const n=Number(value||0);return Number.isFinite(n)?Number(n.toFixed(2)):0;};
   const normalize=(row:Record<string,any>)=>({reference_no:String(row.reference_no||"").trim(),job_card_number:String(row.job_card_number||"").trim().toUpperCase(),transaction_date:iso(row.transaction_date),processed_date:iso(row.processed_date),amount_to_be_credited:amount(row.amount_to_be_credited),credit_amount:amount(row.credit_amount),status:String(row.status||"").trim().toLowerCase()||"blank",rejection_reason:String(row.rejection_reason||"").trim()});
   const oldRows=saved.map(normalize),newRows=incoming.map((row:Record<string,any>)=>normalize(row));
   const oldMap=new Map(oldRows.map(row=>[row.reference_no,row])),newMap=new Map(newRows.map(row=>[row.reference_no,row]));
   const changed:string[]=[],unchangedReferences:string[]=[];
   for(const [ref,row] of newMap){const old=oldMap.get(ref);if(!old)changed.push(ref);else if(JSON.stringify(old)!==JSON.stringify(row))changed.push(ref);else unchangedReferences.push(ref);}
   for(const ref of oldMap.keys())if(!newMap.has(ref))changed.push(ref);
   const sharedReferenceCount=[...newMap.keys()].filter(ref=>oldMap.has(ref)).length;
   const identity_mismatch=oldRows.length>0&&newRows.length>0&&sharedReferenceCount===0;
   const unchanged=changed.length===0&&oldRows.length===newRows.length;
   return reply({approved:true,found:true,batch,unchanged,identity_mismatch,comparison_available:true,changed_count:changed.length,changed_references:changed.slice(0,100),unchanged_references:unchangedReferences,saved_rows:oldRows.length,incoming_rows:newRows.length});
  }
  if(action==="get-fto-batch"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can access FTO tracking."},403);
   const ftoNumber=String(body.fto_number||"").trim().toUpperCase().slice(0,100);
   if(!ftoNumber)return reply({error:"Enter the FTO number first."},400);
   const {data:batch,error:batchError}=await admin.from("vbgramg_fto_batches").select("id,fto_number,contribution_period,ledger_charge_period,period_id,village_scope,first_imported_at,last_checked_at").eq("fto_number",ftoNumber).maybeSingle();
   if(batchError)throw batchError;
   return reply({approved:true,found:Boolean(batch),batch:batch||null});
  }

  if(action==="get-fto-applicant-review"){
   if(approved.role!=="admin")return reply({error:"Only an administrator can review FTO applicant matches."},403);
   const ftoNumber=String(body.fto_number||"").trim().toUpperCase();
   if(!ftoNumber)return reply({error:"An FTO number is required."},400);
   const {data:batch,error:batchError}=await admin.from("vbgramg_fto_batches").select("id,fto_number,contribution_period,ledger_charge_period").eq("fto_number",ftoNumber).maybeSingle();
   if(batchError)throw batchError;
   if(!batch)return reply({error:"FTO batch was not found."},404);
   const mis=await loadActiveMisApplicants(admin);
   if(!mis.size)return reply({error:"There is no active MIS import."},409);
   const {data:transactions,error:txError}=await admin.from("vbgramg_fto_transactions").select("id,job_card_number,person_name,ledger_entry_id,status,calculated_charge,is_in_scope").eq("batch_id",batch.id).eq("is_in_scope",true).not("ledger_entry_id","is",null);
   if(txError)throw txError;
   const ledgerIds=[...new Set((transactions||[]).map(t=>String(t.ledger_entry_id)).filter(Boolean))];
   if(!ledgerIds.length)return reply({approved:true,fto_number:ftoNumber,automatic_matches:0,pending:[]});
   const {data:ledger,error:ledgerError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,applicant_name,applicant_number,applicant_unique_id,fto_applicant_name,entry_type,note").in("id",ledgerIds).eq("entry_type","charge");
   if(ledgerError)throw ledgerError;
   const ledgerById=new Map((ledger||[]).map(row=>[String(row.id),row]));
   const byLedger=new Map<string,any[]>();
   for(const tx of transactions||[]){const id=String(tx.ledger_entry_id||"");if(!id||!ledgerById.has(id)||!String(tx.person_name||"").trim())continue;if(!byLedger.has(id))byLedger.set(id,[]);byLedger.get(id)!.push(tx);}
   const pending:any[]=[];let automaticMatches=0;
   for(const [ledgerId,txs] of byLedger){
    const entry=ledgerById.get(ledgerId),jobCard=String(entry.job_card_number||"");
    const counts=new Map<string,number>();for(const tx of txs){const n=String(tx.person_name||"").trim();counts.set(n,(counts.get(n)||0)+1);}
    const ftoName=[...counts].sort((a,b)=>b[1]-a[1])[0]?.[0]||String(entry.person_name||"");
    const ranked=rankActiveMisApplicants(mis,jobCard,ftoName);
    if(!ranked.length){pending.push({ledger_entry_id:ledgerId,job_card_number:jobCard,fto_name:ftoName,reason:"No active MIS applicants found for this job card",candidates:[]});continue;}
    const best=ranked[0],second=ranked[1],gap=second?best.match_percentage-second.match_percentage:100;
    const hasSavedMapping=Boolean(entry.applicant_unique_id||entry.applicant_name||entry.applicant_number);
    const previousFtoName=String(entry.fto_applicant_name||"").trim();
    if(hasSavedMapping&&!previousFtoName){
     const {error:baselineError}=await admin.from("vbgramg_charge_ledger").update({fto_applicant_name:ftoName}).eq("id",ledgerId);
     if(baselineError)throw baselineError;
     continue;
    }
    if(hasSavedMapping){
     if(normalizeApplicantIdentity(previousFtoName)===normalizeApplicantIdentity(ftoName))continue;
     pending.push({ledger_entry_id:ledgerId,job_card_number:jobCard,fto_name:ftoName,attached_applicant:entry.applicant_name||null,reason:"FTO name differs from the applicant already attached. Existing mapping has been retained; confirm any change explicitly.",candidates:ranked.slice(0,10)});
     continue;
    }
    if(best.match_percentage>=80&&(!second||second.match_percentage<80||gap>=10)){
     const {error:updateError}=await admin.from("vbgramg_charge_ledger").update({applicant_name:best.applicant_name,applicant_number:best.applicant_number,applicant_unique_id:best.applicant_unique_id,fto_applicant_name:ftoName}).eq("id",ledgerId);
     if(updateError)throw updateError;automaticMatches++;
    }else{
     pending.push({ledger_entry_id:ledgerId,job_card_number:jobCard,fto_name:ftoName,reason:best.match_percentage<80?"Best match is below 80%":(second&&second.match_percentage>=80&&gap<10?"Top two candidates are less than 10 percentage points apart":"Needs confirmation"),candidates:ranked.slice(0,10)});
    }
   }
   return reply({approved:true,fto_number:ftoNumber,automatic_matches:automaticMatches,pending});
  }
  if(action==="save-fto-applicant-match"){
   if(approved.role!=="admin")return reply({error:"Only an administrator can confirm FTO applicant matches."},403);
   const ledgerId=String(body.ledger_entry_id||"").trim(),jobCard=String(body.job_card_number||"").trim(),applicantUniqueId=String(body.applicant_unique_id||"").trim(),applicantName=String(body.applicant_name||"").trim(),applicantNumber=String(body.applicant_number||"").trim();
   if(!ledgerId||!jobCard||!applicantName)return reply({error:"Choose a valid MIS applicant."},400);
   const mis=await loadActiveMisApplicants(admin),candidates=mis.get(jobCard)||[];
   const chosen=candidates.find(a=>(applicantUniqueId&&a.applicant_unique_id===applicantUniqueId)||(!applicantUniqueId&&String(a.applicant_name)===applicantName&&String(a.applicant_number||"")===applicantNumber));
   if(!chosen)return reply({error:"The selected applicant is not present in the current active MIS for this job card. Refresh the review and try again."},409);
   const {data:ledger,error:ledgerError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,entry_type").eq("id",ledgerId).maybeSingle();
   if(ledgerError)throw ledgerError;
   if(!ledger||String(ledger.job_card_number)!==jobCard||ledger.entry_type!=="charge")return reply({error:"The contribution charge no longer matches this review."},409);
   const {error:updateError}=await admin.from("vbgramg_charge_ledger").update({applicant_name:chosen.applicant_name,applicant_number:chosen.applicant_number,applicant_unique_id:chosen.applicant_unique_id,fto_applicant_name:String(body.fto_name||"").trim()||null}).eq("id",ledgerId);
   if(updateError)throw updateError;
   return reply({approved:true,saved:true,applicant:chosen});
  }
  if(action==="calculate-fto-charges"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can calculate FTO charges."},403);
   const divisor=Number(body.divisor),multiplier=Number(body.multiplier),rows=body.rows;
   if(!Number.isFinite(divisor)||divisor<=0||divisor>1000000000||!Number.isFinite(multiplier)||multiplier<=0||multiplier>1000000)return reply({error:"Divisor and multiplier must be finite positive numbers within the allowed range."},400);
   if(!Array.isArray(rows)||rows.length<1||rows.length>5000)return reply({error:"The FTO calculation must contain 1–5,000 rows."},400);
   const {data:calculations,error}=await admin.rpc("vbgramg_calculate_fto_charges",{p_rows:rows,p_divisor:divisor,p_multiplier:multiplier});
   if(error)throw error;
   if(!Array.isArray(calculations)||calculations.length!==rows.length)return reply({error:"PostgreSQL returned an incomplete FTO calculation."},500);
   return reply({approved:true,calculations});
  }
  if(action==="sync-fto-batch"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can synchronize FTO transactions."},403);
   const ftoNumber=String(body.fto_number||"").trim().toUpperCase().slice(0,100);
   let periodId=String(body.period_id||"").trim();
   const contributionPeriod=String(body.contribution_period||"").trim().slice(0,100);
   const chargePeriod=String(body.charge_period||"").trim();
   const periodMatch=chargePeriod.match(/^(\d{4})-(\d{2})-01$/);
   const villageScope="ACTIVE MIS JOB CARDS";
   const rows=body.rows;
   const divisor=Number(body.divisor),multiplier=Number(body.multiplier);
   if(!Number.isFinite(divisor)||divisor<=0||divisor>1000000000||!Number.isFinite(multiplier)||multiplier<=0||multiplier>1000000)return reply({error:"Divisor and multiplier must be finite positive numbers within the allowed range."},400);
   if(!ftoNumber)return reply({error:"Enter the FTO number shown on the government page."},400);
   if(!contributionPeriod)return reply({error:"Select a contribution period from the shared list."},400);
   if(!periodMatch||Number(periodMatch[2])<1||Number(periodMatch[2])>12)return reply({error:"Enter a recognizable month and year, such as August 2026."},400);
   if(!Array.isArray(rows)||rows.length<1||rows.length>5000)return reply({error:"The pasted FTO must contain 1–5,000 transaction rows."},400);
   const sourceSha=String(body.source_sha256||"").toLowerCase();
   const sourceFilename=("FTO-"+ftoNumber).slice(0,255);
   if(!/^[a-f0-9]{64}$/.test(sourceSha))return reply({error:"FTO synchronization identity is missing. Reload the preview and try again."},400);
   const reviewed=Array.isArray(body.reviewed_duplicates)?new Set(body.reviewed_duplicates.map((v:unknown)=>String(v||"").trim())):new Set<string>();
   const reviewedNew=Array.isArray(body.reviewed_new_job_cards)?new Set(body.reviewed_new_job_cards.map((v:unknown)=>String(v||"").trim())):new Set<string>();
   // Manual ledger charges are never adopted implicitly. The preview must explicitly
   // choose whether each existing manual charge is linked to this FTO or kept separate.
   const rawManualActions=body.manual_charge_actions&&typeof body.manual_charge_actions==="object"?body.manual_charge_actions as Record<string,unknown>:{};
   const manualChargeActions=new Map<string,"link"|"keep_separate">();
   const manualAmountConfirmations=new Set(Array.isArray(body.manual_charge_amount_confirmations)?body.manual_charge_amount_confirmations.map((v:unknown)=>String(v||"").trim().toUpperCase()):[]);
   for(const [rawCard,rawAction] of Object.entries(rawManualActions)){
    const card=String(rawCard||"").trim().toUpperCase(),action=String(rawAction||"").trim();
    if(!card||!["link","keep_separate"].includes(action))return reply({error:"A manual charge reconciliation choice is invalid. Refresh the preview and choose Link to FTO or Keep separate."},400);
    manualChargeActions.set(card,action as "link"|"keep_separate");
   }

   const rowsSeen=rows.length;
   // Official FTOs contain exactly one transaction per job card. Validate the
   // complete pasted snapshot before MIS filtering or ledger reconciliation so
   // duplicate source rows can never be silently aggregated into one charge.
   const jobCardOccurrences=new Map<string,number>();
   for(const raw of rows){
    const card=String(raw?.job_card_number||"").trim().toUpperCase().slice(0,100);
    if(card)jobCardOccurrences.set(card,(jobCardOccurrences.get(card)||0)+1);
   }
   const duplicateJobCards=[...jobCardOccurrences.entries()].filter(([,count])=>count>1).map(([card])=>card).sort();
   if(duplicateJobCards.length)return reply({
    error:"This FTO contains more than one transaction for the same job card. No changes were made. Correct the pasted source and try again.",
    duplicate_job_cards:duplicateJobCards
   },400);
   const activeMisApplicants=await loadActiveMisApplicants(admin);
   if(!activeMisApplicants.size)return reply({error:"There is no active MIS import available. Import or activate MIS before synchronizing an FTO."},409);
   const activeJobCards=new Set([...activeMisApplicants.keys()].map(card=>String(card).trim().toUpperCase()));
   const rawReconciliationApplicants=body.reconciliation_applicants&&typeof body.reconciliation_applicants==="object"?body.reconciliation_applicants as Record<string,any>:{};
   const reconciliationApplicants=new Map<string,Record<string,string|null>>();
   for(const [rawCard,rawApplicant] of Object.entries(rawReconciliationApplicants)){
    const card=String(rawCard||"").trim().toUpperCase();
    if(!card||!rawApplicant||typeof rawApplicant!=="object")return reply({error:"An applicant mapping in the reconciliation preview is invalid."},400);
    const candidates=activeMisApplicants.get(card)||[...(activeMisApplicants.entries())].find(([key])=>String(key).trim().toUpperCase()===card)?.[1]||[];
    const uniqueId=String(rawApplicant.applicant_unique_id||"").trim(),name=String(rawApplicant.applicant_name||"").trim(),number=String(rawApplicant.applicant_number||"").trim();
    const chosen=candidates.find(a=>(uniqueId&&a.applicant_unique_id===uniqueId)||(!uniqueId&&String(a.applicant_name)===name&&String(a.applicant_number||"")===number));
    if(!chosen)return reply({error:"The selected applicant for "+card+" is not in the current active MIS. Refresh the preview and try again."},409);
    reconciliationApplicants.set(card,chosen);
   }
   const localInputRows=rows;
   const {data:chargeCalculations,error:calculationError}=await admin.rpc("vbgramg_calculate_fto_charges",{p_rows:localInputRows.map((raw:Record<string,any>,row_index:number)=>({row_index,credit_amount:raw.credit_amount,status:raw.status})),p_divisor:divisor,p_multiplier:multiplier});
   if(calculationError)throw calculationError;
   if(!Array.isArray(chargeCalculations)||chargeCalculations.length!==localInputRows.length)return reply({error:"PostgreSQL returned an incomplete FTO calculation. Nothing was synchronized."},500);
   const calculatedByIndex=new Map<number,number>();
   for(const item of chargeCalculations){const index=Number(item.row_index),amount=Number(item.calculated_charge);if(!Number.isInteger(index)||index<0||index>=localInputRows.length||!Number.isFinite(amount)||amount<0)return reply({error:"PostgreSQL returned an invalid FTO charge calculation."},500);calculatedByIndex.set(index,amount);}
   if(calculatedByIndex.size!==localInputRows.length)return reply({error:"PostgreSQL returned an incomplete FTO calculation. Nothing was synchronized."},500);
   const excludedOutsideActiveMis=rowsSeen-localInputRows.filter((raw:Record<string,any>)=>activeJobCards.has(String(raw?.job_card_number||"").trim().toUpperCase())).length;
   const normalized:Record<string,any>[]=[];
   const seenReferences=new Map<string,string>();
   for(let rowIndex=0;rowIndex<localInputRows.length;rowIndex++){
    const raw=localInputRows[rowIndex];
    const referenceNo=String(raw.reference_no||"").trim().slice(0,200);
    const jobCard=String(raw.job_card_number||"").trim().toUpperCase().slice(0,100);
    const villageName=String(raw.village_name||"").trim().slice(0,150);
    const personName=String(raw.person_name||"").trim().slice(0,200);
    const status=String(raw.status||"").trim().toLowerCase();
    const creditAmount=Number(raw.credit_amount);
    const amountToCredit=Number(raw.amount_to_be_credited);
    const calculatedCharge=Number(calculatedByIndex.get(rowIndex));
    const transactionDate=String(raw.transaction_date||"").trim();
    const processedDate=String(raw.processed_date||"").trim();
    const rejectionReason=String(raw.rejection_reason||"").trim().slice(0,500);
    if(!referenceNo||!/^MZ-\d{2}-/i.test(jobCard)||!personName||personName.toLowerCase()==="name needs review")return reply({error:"Every transaction must have a reference number, valid job card, and account-holder/applicant name. Nothing was synchronized."},400);
    if(!["blank","processed","rejected","other"].includes(status))return reply({error:"A transaction has an unsupported status. Reload the table and review it."},400);
    if(["blank","processed"].includes(status)&&(!Number.isFinite(creditAmount)||creditAmount<=0||!Number.isFinite(calculatedCharge)||calculatedCharge<=0||calculatedCharge>10000000))return reply({error:"A blank or processed transaction has an invalid credit amount or calculated charge."},400);
    if(transactionDate&&(!/^\d{4}-\d{2}-\d{2}$/.test(transactionDate)||Number.isNaN(Date.parse(transactionDate))))return reply({error:"A transaction date is invalid."},400);
    if(processedDate&&(!/^\d{4}-\d{2}-\d{2}$/.test(processedDate)||Number.isNaN(Date.parse(processedDate))))return reply({error:"A processed date is invalid."},400);
    if(seenReferences.has(referenceNo))return reply({error:"Reference number "+referenceNo+" appears more than once in this pasted FTO. Review the source table before synchronizing."},400);
    seenReferences.set(referenceNo,jobCard);
    normalized.push({
      reference_no:referenceNo,job_card_number:jobCard,village_name:villageName,
      person_name:personName,transaction_date:transactionDate||null,processed_date:processedDate||null,
      amount_to_be_credited:Number.isFinite(amountToCredit)&&amountToCredit>0?amountToCredit:null,
      credit_amount:Number.isFinite(creditAmount)&&creditAmount>0?creditAmount:null,
      calculated_charge:status==="rejected"||status==="other"?0:calculatedCharge,
      status,rejection_reason:rejectionReason||null,
      is_in_scope:activeJobCards.has(jobCard),
      source_row:raw.source_row&&typeof raw.source_row==="object"?raw.source_row:{}
    });
   }
   const {data:batchOld,error:batchOldError}=await admin.from("vbgramg_fto_batches").select("id,fto_number,contribution_period,ledger_charge_period,period_id,village_scope").eq("fto_number",ftoNumber).maybeSingle();
   if(batchOldError)throw batchOldError;
   if(!periodId){
    let {data:legacyPeriod,error:legacyPeriodError}=await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,status").eq("period_name",contributionPeriod).eq("contribution_month",chargePeriod).maybeSingle();
    if(legacyPeriodError)throw legacyPeriodError;
    if(!legacyPeriod)return reply({error:"The selected charge round does not exist in Period Management. Create or select the correct round first."},400);
    periodId=String(legacyPeriod.id);
   }
   const {data:selectedPeriod,error:selectedPeriodError}=await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,status").eq("id",periodId).maybeSingle();
   if(selectedPeriodError)throw selectedPeriodError;
   if(!selectedPeriod||selectedPeriod.contribution_month!==chargePeriod||selectedPeriod.period_name!==contributionPeriod)return reply({error:"Select a shared charge round for the chosen contribution month."},400);
   if(batchOld&&selectedPeriod.status!=="open"&&String(batchOld.period_id||"")!==periodId)return reply({error:"That period is closed. Reopen it before assigning an FTO."},409);
   if(!batchOld&&selectedPeriod.status!=="open")return reply({error:"That period is closed. Reopen it before importing an FTO."},409);
   if(batchOld&&(String(batchOld.contribution_period)!==contributionPeriod||String(batchOld.ledger_charge_period||"")!==chargePeriod)){
    return reply({error:"This FTO number is already saved with period \""+String(batchOld.contribution_period)+"\". The saved period cannot be changed during a re-import. If this is genuinely a different FTO, verify the FTO number first.",saved_period:batchOld.contribution_period},409);
   }
   if(batchOld&&batchOld.period_id&&String(batchOld.period_id)!==periodId){
    return reply({error:"This FTO is already assigned to a different contribution round. Use the explicit FTO period reassignment workflow before importing it into another round."},409);
   }
   const {data:exemptionRows,error:exemptionError}=await admin.from("vbgramg_contribution_exemptions").select("job_card_number");
   if(exemptionError)throw exemptionError;
   const exemptCards=new Set((exemptionRows||[]).map(r=>String(r.job_card_number)));
   let skippedDuplicateReferences:string[]=[];
   let chargeCandidateRows=normalized.filter(r=>r.is_in_scope&&!exemptCards.has(String(r.job_card_number))&&["blank","processed"].includes(String(r.status))&&Number(r.calculated_charge||0)>0);
   let incomingRefs=chargeCandidateRows.map(r=>String(r.reference_no));
   // Check all incoming references, including rejected rows. A reference already
   // attached to this same FTO/card/period is an update, never a duplicate blocker.
   if(normalized.length){
    const allIncomingRefs=normalized.map(r=>String(r.reference_no));
    const {data:ledgerRefMatches,error:ledgerRefError}=await admin.from("vbgramg_charge_ledger").select("job_card_number,charge_period,period_id,note,reference_numbers").overlaps("reference_numbers",allIncomingRefs);
    if(ledgerRefError)throw ledgerRefError;
    for(const input of normalized){
     for(const old of ledgerRefMatches||[]){
      if(!(old.reference_numbers||[]).includes(String(input.reference_no)))continue;
      const sameFtoLedger=String(old.job_card_number)===String(input.job_card_number)&&String(old.charge_period||"")===chargePeriod&&(!old.period_id||String(old.period_id)===periodId);
      const needsCharge=input.is_in_scope&&!exemptCards.has(String(input.job_card_number))&&["blank","processed"].includes(String(input.status))&&Number(input.calculated_charge||0)>0;
      if(needsCharge&&!sameFtoLedger)skippedDuplicateReferences.push(String(input.reference_no));
     }
    }
   }
   skippedDuplicateReferences=[...new Set(skippedDuplicateReferences)];
   const skippedDuplicateSet=new Set(skippedDuplicateReferences);
   if(skippedDuplicateSet.size){
    // Keep duplicate rows in the FTO snapshot/history, but exclude them from
    // contribution reconciliation. Removing them here would mark an older
    // same-batch transaction as omitted and could void its existing charge.
    chargeCandidateRows=normalized.filter(r=>r.is_in_scope&&!exemptCards.has(String(r.job_card_number))&&!skippedDuplicateSet.has(String(r.reference_no))&&["blank","processed"].includes(String(r.status))&&Number(r.calculated_charge||0)>0);
    incomingRefs=chargeCandidateRows.map(r=>String(r.reference_no));
   }
   const snapshotReferenceSet=new Set(normalized.map(r=>String(r.reference_no)));
   const incomingCards=[...new Set(normalized.filter(r=>r.is_in_scope).map(r=>String(r.job_card_number)))];
   const chargeCandidateCards=[...new Set(chargeCandidateRows.map(r=>String(r.job_card_number)))];
   if(chargeCandidateCards.length){
    const {data:periodTxs,error:periodTxError}=await admin.from("vbgramg_fto_transactions").select("job_card_number,batch_id,calculated_charge,status,is_in_scope").in("job_card_number",chargeCandidateCards);
    if(periodTxError)throw periodTxError;
    const periodBatchIds=[...new Set((periodTxs||[]).map(r=>String(r.batch_id)))];
    let periodBatches:Record<string,any>[]=[];
    if(periodBatchIds.length){const {data,error}=await admin.from("vbgramg_fto_batches").select("id,fto_number,ledger_charge_period,period_id").in("id",periodBatchIds);if(error)throw error;periodBatches=data||[];}
    const periodBatchMap=new Map(periodBatches.map(b=>[String(b.id),b]));
    const conflictingFtos=[...new Set((periodTxs||[]).filter(tx=>tx.is_in_scope===true&&["blank","processed"].includes(String(tx.status))&&Number(tx.calculated_charge||0)>0).filter(tx=>{const b=periodBatchMap.get(String(tx.batch_id));return b&&String(b.period_id||"")===periodId&&String(b.fto_number||"")!==ftoNumber;}).map(tx=>String(tx.job_card_number)))];
    if(conflictingFtos.length)return reply({error:"A different FTO number already has a charge for one or more job cards in this contribution period. Resolve the duplicate FTO before synchronizing.",conflicting_job_cards:conflictingFtos,fto_number:ftoNumber,charge_period:chargePeriod},409);
   }
   if(incomingRefs.length){
    const {data:oldRefs,error:oldRefsError}=await admin.from("vbgramg_fto_transactions").select("reference_no,job_card_number,batch_id").in("reference_no",incomingRefs);
    if(oldRefsError)throw oldRefsError;
    // A reference is unique within its FTO, not globally.
    if(batchOld?.id){
     for(const input of chargeCandidateRows){
      for(const old of oldRefs||[]){
       if(String(old.batch_id)!==String(batchOld.id)||String(old.reference_no)!==String(input.reference_no))continue;
       if(String(old.job_card_number)!==String(input.job_card_number)){
        return reply({error:"Reference number "+input.reference_no+" is already assigned to a different job card in this FTO. Nothing was synchronized.",reference_no:input.reference_no},409);
       }
      }
     }
    }
   }
   if(chargeCandidateCards.length){
    const {data:existingLedger,error:existingLedgerError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,amount,is_deferred,note,reference_numbers,period_id").in("job_card_number",chargeCandidateCards).eq("entry_type","charge").eq("charge_period",chargePeriod);
    if(existingLedgerError)throw existingLedgerError;
    // Manual-charge decisions are validated against the complete snapshot below,
    // after all related FTO transactions and ledger rows have been loaded.
    const {data:knownLedger,error:knownLedgerError}=await admin.from("vbgramg_charge_ledger").select("job_card_number").in("job_card_number",chargeCandidateCards);
    if(knownLedgerError)throw knownLedgerError;
    const {data:knownCitizens,error:knownCitizensError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number").in("job_card_number",chargeCandidateCards);
    if(knownCitizensError)throw knownCitizensError;
    const known=new Set([...(knownLedger||[]).map(r=>String(r.job_card_number)),...(knownCitizens||[]).map(r=>String(r.job_card_number))]);
    // New-to-ledger job cards are valid when they exist in the active MIS.
   }
   const batchId=String(batchOld?.id||crypto.randomUUID());
   const oldBatchTransactions:Record<string,any>[]=[];
   if(batchOld?.id){
    const {data,error}=await admin.from("vbgramg_fto_transactions").select("*").eq("batch_id",batchId);
    if(error)throw error;oldBatchTransactions.push(...(data||[]));
   }
   const nowIso=new Date().toISOString();
   const oldByRef=new Map(oldBatchTransactions.map(r=>[String(r.reference_no),r]));
   const transactionRows:Record<string,any>[]=[];
   const statusHistory:Record<string,any>[]=[];
   for(const row of normalized){
    const old=oldByRef.get(String(row.reference_no));
    // A conflicting duplicate must not overwrite the previously saved row
    // belonging to this FTO. Its existing snapshot remains current and unchanged.
    if(skippedDuplicateSet.has(String(row.reference_no))&&old)continue;
    const id=String(old?.id||crypto.randomUUID());
    transactionRows.push({...row,id,batch_id:batchId,last_seen_at:nowIso,updated_at:nowIso,
      created_at:old?.created_at||nowIso,is_current:true,is_in_scope:row.is_in_scope===true,
      ledger_entry_id:old?.ledger_entry_id||null});
    if(!old||String(old.status||"")!==String(row.status||"")||
       Number(old.calculated_charge||0)!==Number(row.calculated_charge||0)||
       String(old.processed_date||"")!==String(row.processed_date||"")){
     statusHistory.push({transaction_id:id,old_status:old?.status??null,new_status:row.status,
      old_calculated_charge:old?Number(old.calculated_charge||0):null,
      new_calculated_charge:Number(row.calculated_charge||0),
      old_processed_date:old?.processed_date||null,new_processed_date:row.processed_date||null,
      changed_by:authData.user.id,fto_number:ftoNumber,reference_no:row.reference_no,
      note:old?"Status, processed date, or calculated charge changed during FTO synchronization":"Transaction first recorded from pasted FTO"});
    }
   }
   const omittedTransactions=oldBatchTransactions.filter(tx=>!snapshotReferenceSet.has(String(tx.reference_no||"")));
   const omittedIds=omittedTransactions.map(tx=>String(tx.id));
   const affectedCards=[...new Set([...incomingCards,...oldBatchTransactions.map(tx=>String(tx.job_card_number||"").trim()).filter(Boolean)])];
   const {data:trackedRows,error:trackedError}=affectedCards.length
    ?await admin.from("vbgramg_fto_transactions").select("id,batch_id,reference_no,job_card_number,calculated_charge,status,processed_date,is_in_scope,is_current,last_seen_at,ledger_entry_id").in("job_card_number",affectedCards)
    :{data:[],error:null};
   if(trackedError)throw trackedError;
   const trackedBatchIds=[...new Set((trackedRows||[]).map(r=>String(r.batch_id)))];
   let trackBatches:Record<string,any>[]=[];
   if(trackedBatchIds.length){const {data,error}=await admin.from("vbgramg_fto_batches").select("id,ledger_charge_period,period_id,fto_number").in("id",trackedBatchIds);if(error)throw error;trackBatches=data||[];}
   const batchPeriod=new Map(trackBatches.map(r=>[String(r.id),{month:String(r.ledger_charge_period||""),periodId:String(r.period_id||""),fto:String(r.fto_number||"") }]));
   const relevant=(trackedRows||[]).filter(r=>{const p=batchPeriod.get(String(r.batch_id));return p?.month===chargePeriod&&p.periodId===periodId&&r.is_in_scope===true&&r.is_current===true;});
   const snapshotByIdentity=new Map<string,Record<string,any>>();
   for(const tx of relevant){
    const key=String(tx.batch_id)+"::"+String(tx.reference_no);
    if(String(tx.batch_id)===batchId&&!snapshotReferenceSet.has(String(tx.reference_no)))continue;
    const incoming=String(tx.batch_id)===batchId?transactionRows.find(x=>String(x.reference_no)===String(tx.reference_no)):undefined;
    snapshotByIdentity.set(key,incoming||tx);
   }
   // Include first-import rows in the reconciliation snapshot as well. On a new
   // FTO batch there are no persisted transaction rows yet, so the tracked-row
   // query above is empty; without this merge the ledger plan would be empty even
   // though the incoming FTO rows are valid and in scope.
   for(const tx of transactionRows){
    const reference=String(tx.reference_no||"");
    if(tx.is_in_scope!==true||skippedDuplicateSet.has(reference))continue;
    snapshotByIdentity.set(batchId+"::"+reference,tx);
   }
   const txByCard=new Map<string,Record<string,any>[]>();
   for(const tx of snapshotByIdentity.values()){const card=String(tx.job_card_number);if(!txByCard.has(card))txByCard.set(card,[]);txByCard.get(card)!.push(tx);}
   const {data:ledgerRows,error:ledgerError}=affectedCards.length
    ?await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,entry_type,amount,charge_period,entry_date,note,import_id,created_by,is_deferred,is_voided,reference_numbers,period_id,applicant_name,applicant_number,applicant_unique_id,fto_applicant_name").in("job_card_number",affectedCards).eq("charge_period",chargePeriod).in("entry_type",["charge","other_charge"])
    :{data:[],error:null};
   if(ledgerError)throw ledgerError;
   const manualReviewIssues:string[]=[];
   for(const card of affectedCards){
    if(exemptCards.has(card))continue;
    const txs=txByCard.get(card)||[];
    const active=txs.filter(tx=>tx.is_in_scope===true&&!skippedDuplicateSet.has(String(tx.reference_no))&&["blank","processed"].includes(String(tx.status||"").trim().toLowerCase())&&Number(tx.calculated_charge||0)>0);
    if(!active.length)continue;
    const cardRows=(ledgerRows||[]).filter(r=>String(r.job_card_number)===card&&r.entry_type==="charge"&&(!r.period_id||String(r.period_id)===periodId)&&!r.is_voided);
    const manualRows=cardRows.filter(r=>!/^FTO\b/i.test(String(r.note||""))&&!(Array.isArray(r.reference_numbers)?r.reference_numbers:[]).some((ref:string)=>incomingRefs.includes(String(ref))));
    if(manualRows.length>1){manualReviewIssues.push(card+" (multiple manual charges; resolve individually)");continue;}
    if(manualRows.length===1){
     const action=manualChargeActions.get(card);
     if(!action){manualReviewIssues.push(card+" (choose Link to FTO or Keep manual charge separate)");continue;}
     if(action==="link"&&!manualRows[0].applicant_name&&!manualRows[0].applicant_unique_id&&!manualRows[0].applicant_number&&!reconciliationApplicants.has(card))
      manualReviewIssues.push(card+" (MIS applicant not selected for linking)");
     const incomingAmount=Number(active.reduce((sum,tx)=>sum+Number(tx.calculated_charge||0),0).toFixed(2));
     if(action==="link"&&Math.abs(Number(manualRows[0].amount||0)-incomingAmount)>0.009&&!manualAmountConfirmations.has(card))
      manualReviewIssues.push(card+" (confirm the manual charge amount change)");
    }
   }
   if(manualReviewIssues.length)return reply({error:"Manual charge review is incomplete: "+manualReviewIssues.join(", ")+"."},409);
   const ledgerPlan:Record<string,any>[]=[];
   const transactionLinks:Record<string,string>[]=[];
   const voidLedgerIds:string[]=[];
   const manualLinkIds:string[]=[];
   const chargeGuards:Record<string,any>[]=[];
   let insertedCount=0,updatedCount=0,reconciledCount=0,deletedCount=0;
   for(const card of affectedCards){
    if(exemptCards.has(card))continue;
    const txs=txByCard.get(card)||[];
    const active=txs.filter(tx=>tx.is_in_scope===true&&!skippedDuplicateSet.has(String(tx.reference_no))&&["blank","processed"].includes(String(tx.status||"").trim().toLowerCase())&&Number(tx.calculated_charge||0)>0);
    const refs=[...new Set(active.map(tx=>String(tx.reference_no)))];
    const amount=Number(active.reduce((sum,tx)=>sum+Number(tx.calculated_charge||0),0).toFixed(2));
    const cardRows=(ledgerRows||[]).filter(r=>String(r.job_card_number)===card&&r.entry_type==="charge"&&(!r.period_id||String(r.period_id)===periodId));
    const ftoRows=cardRows.filter(r=>/^FTO\b/i.test(String(r.note||""))&&!/^FTO EXTRA\b/i.test(String(r.note||"")));
    const keeper=ftoRows.find(r=>(r.reference_numbers||[]).some((ref:string)=>refs.includes(String(ref))))||ftoRows[0]||null;
    const manualRows=cardRows.filter(r=>!/^FTO\b/i.test(String(r.note||""))&&!(Array.isArray(r.reference_numbers)?r.reference_numbers:[]).some((ref:string)=>incomingRefs.includes(String(ref))));
    const manualKeeper=manualChargeActions.get(card)==="link"?(manualRows.length===1?manualRows[0]:null):null;
    if(amount>0){
     const isDeferred=active.every(tx=>String(tx.status)==="blank");
     const entryDate=ftoEntryDate(active,isDeferred);
     const activeApplicantName=String(normalized.find(r=>String(r.job_card_number)===card)?.person_name||"");
     const name=activeApplicantName||keeper?.person_name||manualKeeper?.person_name||"Name needs review";
     const applicantChoice=reconciliationApplicants.get(card);
     const ledgerId=String(manualKeeper?.id||keeper?.id||crypto.randomUUID());
     if(manualKeeper)manualLinkIds.push(ledgerId);
     ledgerPlan.push({id:ledgerId,job_card_number:card,person_name:name,entry_type:"charge",amount,
      charge_period:chargePeriod,entry_date:entryDate,note:"FTO import",import_id:null,
      created_by:manualKeeper?.created_by||authData.user.id,is_deferred:isDeferred,
      reference_numbers:refs,applicant_name:applicantChoice?.applicant_name||manualKeeper?.applicant_name||keeper?.applicant_name||null,
      applicant_number:applicantChoice?.applicant_number||manualKeeper?.applicant_number||keeper?.applicant_number||null,
      applicant_unique_id:applicantChoice?.applicant_unique_id||manualKeeper?.applicant_unique_id||keeper?.applicant_unique_id||null,
      period_id:periodId,fto_applicant_name:activeApplicantName||manualKeeper?.fto_applicant_name||keeper?.fto_applicant_name||null,is_voided:false});
     for(const tx of txs){if(!skippedDuplicateSet.has(String(tx.reference_no)))transactionLinks.push({id:String(tx.id),ledger_entry_id:ledgerId});}
     if(manualKeeper)reconciledCount++;else if(keeper)updatedCount++;else insertedCount++;
     chargeGuards.push({job_card_number:card,period_id:periodId,prospective_fto_amount:isDeferred?0:amount});
    }else{
     for(const row of ftoRows){if(!row.is_voided)voidLedgerIds.push(String(row.id));}
     deletedCount+=ftoRows.filter(row=>!row.is_voided).length;
     for(const tx of txs){if(tx.ledger_entry_id)transactionLinks.push({id:String(tx.id),ledger_entry_id:String(tx.ledger_entry_id)});}
     if(ftoRows.length)chargeGuards.push({job_card_number:card,period_id:periodId,prospective_fto_amount:0});
    }
   }
   const totalAmount=Number(normalized.filter(r=>r.is_in_scope&&!exemptCards.has(String(r.job_card_number))&&!skippedDuplicateSet.has(String(r.reference_no))&&["blank","processed"].includes(String(r.status))).reduce((sum,r)=>sum+Number(r.calculated_charge||0),0).toFixed(2));
   const {data:priorImport,error:priorImportError}=await admin.from("vbgramg_charge_imports").select("id").eq("source_sha256",sourceSha).maybeSingle();
   if(priorImportError)throw priorImportError;
   const importId=String(priorImport?.id||crypto.randomUUID());
   const plan={batch:{id:batchId,fto_number:ftoNumber,contribution_period:contributionPeriod,ledger_charge_period:chargePeriod,village_scope:villageScope,period_id:periodId,created_by:authData.user.id,last_checked_at:nowIso,last_source_sha256:sourceSha,calculation_divisor:divisor,calculation_multiplier:multiplier},
    charge_import:{id:importId,source_filename:sourceFilename,source_sha256:sourceSha,charge_period:chargePeriod,row_count:incomingCards.length,total_amount:totalAmount,imported_by:authData.user.id,notes:("FTO sync "+ftoNumber+"; period label: "+contributionPeriod).slice(0,500),completed_at:nowIso},
    transactions:transactionRows,status_history:statusHistory,omitted_transaction_ids:omittedIds,
    ledger_rows:ledgerPlan,transaction_links:transactionLinks,void_ledger_ids:voidLedgerIds,
    manual_charge_link_ids:manualLinkIds,charge_guards:chargeGuards};
   const {data:rpcResult,error:rpcError}=await admin.rpc("vbgramg_apply_fto_snapshot",{p_plan:plan});
   if(rpcError)throw rpcError;
   if(!rpcResult?.committed)return reply({error:"The atomic FTO snapshot did not confirm a commit. No success was reported."},500);
   return reply({approved:true,fto_number:ftoNumber,contribution_period:contributionPeriod,charge_period:chargePeriod,rows_seen:rowsSeen,local_transactions:normalized.length,excluded_not_in_active_mis:excludedOutsideActiveMis,excluded_other_village:excludedOutsideActiveMis,skipped_duplicate_references:skippedDuplicateReferences,skipped_duplicate_reference_count:skippedDuplicateReferences.length,inserted:insertedCount,updated:updatedCount,reconciled:reconciledCount,deleted:deletedCount,total_amount:totalAmount,batch_id:rpcResult.batch_id,import_id:rpcResult.import_id,atomic:true});

  }

  if(action==="sync-fto-status"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can apply FTO statuses."},403);
   const period=String(body.charge_period||"").trim(),periodId=String(body.period_id||"").trim(),periodMatch=period.match(/^(\d{4})-(\d{2})-01$/);
   if(!periodMatch||Number(periodMatch[2])<1||Number(periodMatch[2])>12)return reply({error:"Choose a valid contribution month."},400);
   if(!periodId)return reply({error:"Select a specific contribution round."},400);
   const {data:selectedRound,error:selectedRoundError}=await admin.from("vbgramg_periods").select("id,contribution_month").eq("id",periodId).maybeSingle();
   if(selectedRoundError)throw selectedRoundError;
   if(!selectedRound||String(selectedRound.contribution_month||"")!==period)return reply({error:"The selected contribution round does not match the month."},400);
   const mode=String(body.mode||""),rows=body.rows;
   if(!["processed","blank","rejected"].includes(mode)||!Array.isArray(rows)||rows.length<1||rows.length>1000)return reply({error:"Choose a valid FTO status action and at least one matching job card."},400);
   const sourceSha=String(body.source_sha256||"").toLowerCase(),sourceFilename=String(body.source_filename||"").trim().slice(0,255);
   if(!/^[a-f0-9]{64}$/.test(sourceSha)||!sourceFilename)return reply({error:"FTO action identity is missing. Reload the preview and try again."},400);
   const reviewed=Array.isArray(body.reviewed_duplicates)?new Set(body.reviewed_duplicates.map((v:unknown)=>String(v||"").trim())):new Set<string>();
   const reviewedNew=Array.isArray(body.reviewed_new_job_cards)?new Set(body.reviewed_new_job_cards.map((v:unknown)=>String(v||"").trim())):new Set<string>();
   const normalized:Record<string,any>[]=[];const seen=new Set<string>();let totalAmount=0;
   for(const raw of rows){
    const jobCard=String(raw.job_card_number||"").trim(),personName=String(raw.person_name||"").trim(),status=String(raw.status||"").trim().toLowerCase(),amount=Number(raw.amount),referenceNumbers=Array.isArray(raw.reference_numbers)?[...new Set(raw.reference_numbers.map((v:unknown)=>String(v||"").trim()).filter(Boolean))]:[];
    if(!jobCard||!personName||personName.toLowerCase()==="name needs review"||seen.has(jobCard)||status!==mode)return reply({error:"An FTO row is invalid, duplicated, or does not match the selected status. Nothing was changed."},400);
    if(mode!=="rejected"&&(!Number.isFinite(amount)||amount<=0||amount>10000000))return reply({error:"An import row has an invalid calculated amount."},400);
    seen.add(jobCard);totalAmount+=mode==="rejected"?0:amount;
    if(mode!=="rejected"&&!referenceNumbers.length)return reply({error:"Every FTO group must include at least one reference number."},400);
    const processedDate=String(raw.processed_date||"").trim();
     if(processedDate&&(!/^\d{4}-\d{2}-\d{2}$/.test(processedDate)||Number.isNaN(Date.parse(processedDate))))return reply({error:"A processed date is invalid."},400);
     normalized.push({job_card_number:jobCard,person_name:personName,amount,is_deferred:mode==="blank",processed_date:processedDate||null,reference_numbers:referenceNumbers});
   }
   const {data:prior,error:priorError}=await admin.from("vbgramg_charge_imports").select("id,status,row_count,total_amount").eq("source_sha256",sourceSha).maybeSingle();
   if(priorError)throw priorError;
   if(prior&&prior.status==="complete")return reply({approved:true,already_applied:true,inserted:0,updated:0,deleted:0,skipped:0,total_amount:prior.total_amount});
   const cards=normalized.map(r=>String(r.job_card_number));
   const {data:existing,error:existingError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,amount,is_deferred,note,import_id,reference_numbers,period_id").in("job_card_number",cards).eq("entry_type","charge").eq("charge_period",period).eq("period_id",periodId);
   if(existingError)throw existingError;
   const allReferences=[...new Set(normalized.flatMap(r=>r.reference_numbers as string[]))];
   const referenceOwners=new Map<string,string>();
   for(const row of normalized){for(const reference of row.reference_numbers as string[]){const owner=referenceOwners.get(reference);if(owner&&owner!==String(row.job_card_number))return reply({error:"The same reference number appears under multiple job cards in this pasted table: "+reference+". Nothing was changed."},400);referenceOwners.set(reference,String(row.job_card_number));}}
   if(mode!=="rejected"&&allReferences.length){
    const {data:refMatches,error:refError}=await admin.from("vbgramg_charge_ledger").select("job_card_number,charge_period,period_id,note,reference_numbers").overlaps("reference_numbers",allReferences);
    if(refError)throw refError;
    const blockers=new Map<string,Set<string>>();
    for(const row of normalized){for(const reference of row.reference_numbers as string[]){for(const old of refMatches||[]){if(!(old.reference_numbers||[]).includes(reference))continue;const oldRefs=old.reference_numbers||[];const rowRefs=row.reference_numbers as string[];const sameReferenceSet=oldRefs.length===rowRefs.length&&rowRefs.every(reference=>oldRefs.includes(reference));const sameExistingCharge=String(old.job_card_number)===String(row.job_card_number)&&String(old.period_id||"")===periodId&&String(old.charge_period||"")===period&&/^FTO\b/i.test(String(old.note||""))&&sameReferenceSet;if(!sameExistingCharge){const card=String(row.job_card_number);if(!blockers.has(card))blockers.set(card,new Set());blockers.get(card)!.add(reference);}}}}
    if(blockers.size)return reply({error:"One or more reference numbers have already been imported for a different job card, period, or non-FTO charge. Duplicate references cannot be imported again.",duplicate_references:[...blockers].map(([job_card_number,refs])=>({job_card_number,reference_numbers:[...refs]}))},409);
   }
   const byCard=new Map<string,Record<string,any>[]>();
   for(const row of existing||[]){const key=String(row.job_card_number);if(!byCard.has(key))byCard.set(key,[]);byCard.get(key)!.push(row);}
   if(mode==="rejected"){
    const deletable=(existing||[]).filter(r=>String(r.period_id||"")===periodId&&/^FTO\b/i.test(String(r.note||""))&&r.is_deferred===true&&normalized.some(n=>String(n.job_card_number)===String(r.job_card_number)&&Array.isArray(r.reference_numbers)&&r.reference_numbers.length===(n.reference_numbers||[]).length&&r.reference_numbers.every((ref:string)=>(n.reference_numbers||[]).includes(String(ref)))));
    if(deletable.length){const {error:deleteError}=await admin.from("vbgramg_charge_ledger").delete().in("id",deletable.map(r=>r.id));if(deleteError)throw deleteError;}
    const {error:auditError}=await admin.from("vbgramg_charge_imports").insert({source_filename:sourceFilename,source_sha256:sourceSha,charge_period:period,row_count:normalized.length,total_amount:0,status:"complete",completed_at:new Date().toISOString(),imported_by:authData.user.id,notes:("FTO rejected-status cleanup; deleted "+deletable.length+" matching deferred charge(s)").slice(0,500)});
    if(auditError&&auditError.code!=="23505")throw auditError;
    return reply({approved:true,deleted:deletable.length,inserted:0,updated:0,skipped:normalized.length-deletable.length,total_amount:0});
   }
   const ftoExisting=(row:Record<string,any>)=>/^FTO\b/i.test(String(row.note||""))&&!/^FTO EXTRA\b/i.test(String(row.note||""));
   const nonFtoDuplicates=normalized.filter(r=>(byCard.get(String(r.job_card_number))||[]).some(old=>!ftoExisting(old)));
   const unreviewed=nonFtoDuplicates.filter(r=>!reviewed.has(String(r.job_card_number)));
   if(unreviewed.length)return reply({error:"Some job cards already have non-FTO charges for this period. Review each flagged row before proceeding.",duplicates:unreviewed.map(r=>({job_card_number:r.job_card_number,person_name:r.person_name,amount:(byCard.get(String(r.job_card_number))||[]).find(old=>!ftoExisting(old))?.amount||0,is_deferred:(byCard.get(String(r.job_card_number))||[]).find(old=>!ftoExisting(old))?.is_deferred||false}))},409);
   const {data:knownLedger,error:knownLedgerError}=await admin.from("vbgramg_charge_ledger").select("job_card_number").in("job_card_number",cards);if(knownLedgerError)throw knownLedgerError;
   const {data:knownCitizens,error:knownCitizensError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number").in("job_card_number",cards);if(knownCitizensError)throw knownCitizensError;
   const known=new Set([...(knownLedger||[]).map(r=>String(r.job_card_number)),...(knownCitizens||[]).map(r=>String(r.job_card_number))]);
   const unknown=cards.filter(card=>!known.has(card)),unverified=unknown.filter(card=>!reviewedNew.has(card));
   if(unverified.length)return reply({error:"New job card(s) need manual verification before import.",unknown_job_cards:unverified},409);
   let importId=prior?.id;
   if(!importId){const {data:created,error:createError}=await admin.from("vbgramg_charge_imports").insert({source_filename:sourceFilename,source_sha256:sourceSha,charge_period:period,row_count:normalized.length,total_amount:totalAmount,status:"staging",imported_by:authData.user.id,notes:("FTO status action: "+mode).slice(0,500)}).select("id").single();if(createError)throw createError;importId=created.id;}
   let inserted=0,updated=0,skipped=0;
   for(const row of normalized){
    const matches=byCard.get(String(row.job_card_number))||[],ftoMatches=matches.filter(ftoExisting);
    if(ftoMatches.length){
     const keeper=ftoMatches[0];
     const {error:updateError}=await admin.from("vbgramg_charge_ledger").update({person_name:row.person_name,amount:row.amount,is_deferred:mode==="blank",entry_date:mode==="blank"?null:(row.processed_date||null),note:"FTO import",reference_numbers:row.reference_numbers,period_id:periodId}).eq("id",keeper.id);
     if(updateError)throw updateError;updated++;
     for(const extra of ftoMatches.slice(1)){if(extra.is_deferred===true){const {error:extraDeleteError}=await admin.from("vbgramg_charge_ledger").delete().eq("id",extra.id);if(extraDeleteError)throw extraDeleteError;}}
     continue;
    }
    const {error:insertError}=await admin.from("vbgramg_charge_ledger").insert({job_card_number:row.job_card_number,person_name:row.person_name,entry_type:"charge",amount:row.amount,charge_period:period,entry_date:mode==="blank"?null:(row.processed_date||null),note:"FTO import",reference_numbers:row.reference_numbers,is_deferred:mode==="blank",created_by:authData.user.id,import_id:importId,period_id:periodId});
    if(insertError)throw insertError;inserted++;
   }
   const {error:completeError}=await admin.from("vbgramg_charge_imports").update({status:"complete",completed_at:new Date().toISOString(),row_count:normalized.length,total_amount:totalAmount}).eq("id",importId);if(completeError)throw completeError;
   return reply({approved:true,inserted,updated,deleted:0,skipped,total_amount:totalAmount,import_id:importId});
  }


  if(action==="save-contribution-extra"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can save extra contribution charges."},403);
   const jobCard=String(body.job_card_number||"").trim(),period=String(body.charge_period||"").trim(),periodId=String(body.period_id||"").trim(),amount=Number(body.amount),reason=String(body.reason||"").trim().slice(0,500);
   const periodMatch=period.match(/^(\d{4})-(\d{2})-01$/);
   if(!jobCard)return reply({error:"Choose a job card."},400);
   if(!periodMatch||Number(periodMatch[2])<1||Number(periodMatch[2])>12)return reply({error:"Choose a valid contribution month."},400);
   if(!periodId)return reply({error:"Select a specific contribution round."},400);
   if(!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Enter an extra amount greater than zero."},400);
   if(!reason)return reply({error:"Enter a reason for the extra amount."},400);
   const {data:result,error}=await admin.rpc("vbgramg_save_contribution_extra",{
    p_job_card_number:jobCard,
    p_charge_period:period,
    p_period_id:periodId,
    p_amount:amount,
    p_reason:reason,
    p_entry_date:new Date().toISOString().slice(0,10),
    p_actor_user_id:authData.user.id
   });
   if(error)throw error;
   if(!result||result.ok!==true)return reply({error:String(result?.error||"Could not save the extra contribution charge.")},Number(result?.status)||400);
   return reply({approved:true,extra:result.extra,entry:result.entry,updated:Boolean(result.updated)});
  }

  if(action==="edit-ledger-entry"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can edit ledger entries."},403);
   const id=String(body.id||"").trim(),amount=Number(body.amount),entryDate=String(body.entry_date||""),note=String(body.note??"").trim().slice(0,200);
   if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id))return reply({error:"A valid ledger entry ID is required."},400);
   if(!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Enter a valid positive amount."},400);
   if(!/^\\d{4}-\\d{2}-\\d{2}$/.test(entryDate)||Number.isNaN(Date.parse(entryDate)))return reply({error:"Enter a valid transaction date."},400);
   const chargePeriod=String(body.charge_period||"").trim();
   if(chargePeriod&&(!/^\\d{4}-\\d{2}-01$/.test(chargePeriod)||Number(chargePeriod.slice(5,7))<1||Number(chargePeriod.slice(5,7))>12))return reply({error:"Choose a valid charge month."},400);
   const {data:result,error}=await admin.rpc("vbgramg_edit_contribution_ledger_entry",{
    p_id:id,
    p_amount:amount,
    p_entry_date:entryDate,
    p_note:note,
    p_charge_period:chargePeriod||null,
    p_is_deferred:typeof body.is_deferred==="boolean"?body.is_deferred:false,
    p_actor_user_id:authData.user.id,
    p_actor_email:email
   });
   if(error)throw error;
   if(!result||result.ok!==true)return reply({error:String(result?.error||"Could not edit the ledger entry.")},Number(result?.status)||400);
   return reply({approved:true,entry:result.entry});
  }
  if(action==="add-waiver"||action==="add-return"||action==="pay-in-full"){
   const jobCard=String(body.job_card_number||"").trim();
   if(!jobCard)return reply({error:"Job card number is required."},400);
   if(action!=="pay-in-full"&&approved.role!=="admin")return reply({error:"Only an approved administrator can record waivers or returns."},403);
   const requestedAmount=Number(body.amount),entryDate=String(body.entry_date||new Date().toISOString().slice(0,10));
   const note=String(body.note||(action==="add-waiver"?"Waiver":action==="add-return"?"Return":"Pay in full")).trim().slice(0,200);
   if(!/^\d{4}-\d{2}-\d{2}$/.test(entryDate)||Number.isNaN(Date.parse(entryDate)))return reply({error:"Enter a valid transaction date."},400);
   const operation=action==="pay-in-full"?"pay_in_full":action==="add-waiver"?"waiver":"return";
   const amount=action==="pay-in-full"?null:requestedAmount;
   const result=await recordContributionWrite(admin,jobCard,operation,amount,entryDate,note,authData.user.id,email);
   if(result.ok!==true)return reply({error:String(result.error||"Could not record the contribution transaction.")},Number(result.status)||400);
   return reply({approved:true,entry:result.entry,balance_before:result.balance_before});
  }

  if(action==="bulk-bank-payment"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can register bulk bank payments."},403);
   const rows=body.entries;
   if(!Array.isArray(rows)||rows.length<1||rows.length>500)return reply({error:"A bulk payment batch must contain 1–500 entries."},400);
   const entryDate=String(body.entry_date||"");
   if(!/^\d{4}-\d{2}-\d{2}$/.test(entryDate)||Number.isNaN(Date.parse(entryDate)))return reply({error:"Choose a valid payment date."},400);
   const seen=new Set<string>(),normalized:{job_card_number:string;amount:number}[]=[];
   for(const rawRow of rows){
    const jobCard=String(rawRow?.job_card_number||"").trim(),amount=Number(rawRow?.amount);
    if(!jobCard||!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Every row must have a valid job card number and positive amount."},400);
    if(seen.has(jobCard))return reply({error:"Duplicate job card in batch: "+jobCard},400);
    seen.add(jobCard);normalized.push({job_card_number:jobCard,amount});
   }
   const {data:result,error:writeError}=await admin.rpc("vbgramg_record_bulk_bank_payment",{
    p_entries:normalized,
    p_entry_date:entryDate,
    p_actor_user_id:authData.user.id,
    p_actor_email:email
   });
   if(writeError)throw writeError;
   if(!result||result.ok!==true)return reply({error:String(result?.error||"Could not save bank payment batch.")},Number(result?.status)||400);
   return reply({approved:true,role:approved.role,entries:result.entries||[],count:Number(result.count)||0,total_amount:Number(result.total_amount)||0,method:"Bank"});
  }

  if(action==="set-payment-allocations"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can review or override payment allocations."},403);
   const transactionId=String(body.transaction_id||"").trim();
   const allocations=body.allocations;
   const source=String(body.allocation_source||"manual");
   if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(transactionId))return reply({error:"A valid payment transaction is required."},400);
   if(!Array.isArray(allocations)||allocations.length>100)return reply({error:"Allocations must be a list of at most 100 period amounts."},400);
   const seenPeriods=new Set<string>();
   for(const item of allocations){
    const periodId=String(item?.period_id||"").trim(),amount=Number(item?.amount);
    if(!periodId||!Number.isFinite(amount)||amount<=0)return reply({error:"Each allocation needs a period and positive amount."},400);
    if(seenPeriods.has(periodId))return reply({error:"Combine duplicate rows for the same period before saving."},400);
    seenPeriods.add(periodId);
   }
   const {data,error}=await admin.rpc("vbgramg_replace_payment_allocations",{p_transaction_id:transactionId,p_allocations:allocations,p_allocation_source:source,p_user_id:authData.user.id});
   if(error)throw error;
   const {data:saved,error:savedError}=await admin.from("vbgramg_payment_allocations").select("id,transaction_id,period_id,job_card_number,amount,allocation_source,confidence,note,created_at,updated_at").eq("transaction_id",transactionId).order("created_at",{ascending:true});
   if(savedError)throw savedError;
   return reply({approved:true,allocation_result:data,allocations:saved||[]});
  }

  if(action==="add-payment"){
   const jobCard=String(body.job_card_number||"").trim(),amount=Number(body.amount),entryDate=String(body.entry_date||"");
   if(!jobCard||!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Enter a valid job card number and positive payment amount."},400);
   if(!/^\d{4}-\d{2}-\d{2}$/.test(entryDate)||Number.isNaN(Date.parse(entryDate)))return reply({error:"Enter a valid payment date."},400);
   const result=await recordContributionWrite(admin,jobCard,"cash_payment",amount,entryDate,"Cash",authData.user.id,email);
   if(result.ok!==true)return reply({error:String(result.error||"Could not record the cash payment.")},Number(result.status)||400);
   return reply({approved:true,role:approved.role,entry:result.entry});
  }
  if(action==="validate-backup-batch"||action==="import-backup-batch"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can import a backup."},403);
   const rows=body.entries;if(!Array.isArray(rows)||rows.length<1||rows.length>250)return reply({error:"Each batch must contain 1–250 ledger entries."},400);
   const normalized:Record<string,unknown>[]=[];
   for(const raw of rows){
    const jobCard=String(raw.job_card_number||"").trim(),personName=String(raw.person_name||"").trim(),sourceId=String(raw.legacy_entry_id||"").trim(),rawType=String(raw.entry_type||""),type=rawType==="return"?"refund":rawType==="forgive"?"charge_waiver":rawType==="sanitationFee"?"other_charge":rawType,amount=Number(raw.amount),note=String(raw.note||"").slice(0,200),ms=Number(raw.source_created_at_ms||0);
    if(!jobCard||!personName||!sourceId||!["charge","payment","refund","charge_waiver","other_charge","return","forgive","sanitationFee"].includes(type)||!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Backup contains an invalid ledger row. Nothing from this batch was imported."},400);
    if(!Number.isFinite(ms)||ms<0)return reply({error:"Backup contains an invalid creation timestamp."},400);
    const chargePeriod=type==="charge"?periodFromNote(note):null;if(type==="charge"&&!chargePeriod)return reply({error:`Could not determine the charge month for ${jobCard}: ${note}`},400);
    const explicitDate=String(raw.entry_date||""),entryDate=/^\d{4}-\d{2}-\d{2}$/.test(explicitDate)?explicitDate:isoDate(ms||Date.now());
    normalized.push({job_card_number:jobCard,person_name:personName,entry_type:type,amount,charge_period:chargePeriod,entry_date:entryDate,note:note||null,legacy_entry_id:sourceId,is_deferred:Boolean(raw.is_deferred),source_created_at_ms:ms,created_at:new Date(ms||Date.now()).toISOString(),created_by:authData.user.id});
   }
   const jobCards=[...new Set(normalized.map(r=>String(r.job_card_number)))],sourceIds=normalized.map(r=>String(r.legacy_entry_id));
   const {data:already,error:alreadyError}=await admin.from("vbgramg_charge_ledger").select("legacy_entry_id,job_card_number,entry_type,amount").in("legacy_entry_id",sourceIds);if(alreadyError)throw alreadyError;
   const alreadyMap=new Map((already||[]).map(r=>[r.legacy_entry_id,r]));
   const {data:january,error:janError}=await admin.from("vbgramg_charge_ledger").select("job_card_number,person_name,amount,charge_period,entry_type").in("job_card_number",jobCards).eq("entry_type","charge").eq("charge_period","2026-01-01");if(janError)throw janError;
   const janMap=new Map((january||[]).map(r=>[r.job_card_number,r])),skipIds=new Set<string>();
   for(const row of normalized){
    const sourceId=String(row.legacy_entry_id),existingSource=alreadyMap.get(sourceId);
    if(existingSource){if(existingSource.job_card_number!==row.job_card_number||existingSource.entry_type!==row.entry_type||Number(existingSource.amount)!==Number(row.amount))return reply({error:`Existing imported row conflicts with backup entry ${sourceId}. No changes were made in this batch.`},409);skipIds.add(sourceId);continue;}
    if(row.entry_type==="charge"&&row.charge_period==="2026-01-01"){const existingJan=janMap.get(String(row.job_card_number));if(existingJan){if(String(existingJan.person_name).trim()!==String(row.person_name).trim()||Number(existingJan.amount)!==Number(row.amount))return reply({error:`January charge mismatch for job card ${row.job_card_number}. Import stopped before writing this batch.`},409);skipIds.add(sourceId);}}
   }
   if(action==="validate-backup-batch")return reply({approved:true,valid:true,rows:normalized.length,alreadyImported:skipIds.size,toImport:normalized.length-skipIds.size});
   const toInsert=normalized.filter(r=>!skipIds.has(String(r.legacy_entry_id)));
   if(toInsert.length){const {error:insertError}=await admin.from("vbgramg_charge_ledger").insert(toInsert);if(insertError)throw insertError;}
   return reply({approved:true,imported:toInsert.length,skipped:skipIds.size});
  }
  if(action==="validate-backup-citizens"||action==="import-backup-citizens"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can import citizen records."},403);
   const rows=body.citizens;if(!Array.isArray(rows)||rows.length<1||rows.length>250)return reply({error:"Each citizen batch must contain 1–250 records."},400);
   const normalized:Record<string,unknown>[]=[];
   for(const raw of rows){
    const jobCard=String(raw.job_card_number||"").trim(),name=String(raw.person_name||"").trim(),legacyId=String(raw.legacy_citizen_id||"").trim();
    if(!jobCard||!name||!legacyId)return reply({error:"Backup contains an invalid citizen record."},400);
    const sourceRecord=raw.source_record&&typeof raw.source_record==="object"?raw.source_record:{};
    normalized.push({job_card_number:jobCard,person_name:name,card_no:String(raw.card_no||""),phone:String(raw.phone||""),legacy_citizen_id:legacyId,source_total_charged:Number(raw.source_total_charged)||0,source_total_paid:Number(raw.source_total_paid)||0,source_balance:Number(raw.source_balance)||0,source_deferred_total:Number(raw.source_deferred_total)||0,source_record:sourceRecord});
   }
   const jobCards=normalized.map(r=>String(r.job_card_number));
   const {data:existing,error:existingError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number,person_name,legacy_citizen_id").in("job_card_number",jobCards);if(existingError)throw existingError;
   const existingMap=new Map((existing||[]).map(r=>[r.job_card_number,r])),skip=new Set<string>();
   for(const row of normalized){const old=existingMap.get(String(row.job_card_number));if(old){if(String(old.person_name).trim()!==String(row.person_name).trim()||old.legacy_citizen_id!==row.legacy_citizen_id)return reply({error:`Citizen record conflicts with existing job card ${row.job_card_number}.`},409);skip.add(String(row.job_card_number));}}
   if(action==="validate-backup-citizens")return reply({approved:true,valid:true,rows:normalized.length,alreadyImported:skip.size,toImport:normalized.length-skip.size});
   const toInsert=normalized.filter(r=>!skip.has(String(r.job_card_number)));
   if(toInsert.length){const {error:insertError}=await admin.from("vbgramg_contribution_citizens").insert(toInsert);if(insertError)throw insertError;}
   return reply({approved:true,imported:toInsert.length,skipped:skip.size});
  }
  if(action==="save-backup-metadata"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can save backup metadata."},403);
   const sourceFilename=String(body.source_filename||"").slice(0,255),sourceSha=String(body.source_sha256||"").toLowerCase();
   const exportedAt=String(body.exported_at||""),citizenCount=Number(body.citizen_count),ledgerCount=Number(body.ledger_count),meta=body.source_meta;
   if(!sourceFilename||!/^[a-f0-9]{64}$/.test(sourceSha)||!Number.isInteger(citizenCount)||citizenCount<0||!Number.isInteger(ledgerCount)||ledgerCount<0||!meta||typeof meta!=="object")return reply({error:"Backup metadata is incomplete or invalid."},400);
   const exportedDate=exportedAt&&Number.isFinite(Date.parse(exportedAt))?new Date(exportedAt).toISOString():null;
   const {data,error}=await admin.from("vbgramg_contribution_backup_imports").upsert({source_filename:sourceFilename,source_sha256:sourceSha,exported_at:exportedDate,citizen_count:citizenCount,ledger_count:ledgerCount,source_meta:meta,imported_by:authData.user.id,completed_at:new Date().toISOString()},{onConflict:"source_sha256"}).select("id,source_filename,source_sha256,citizen_count,ledger_count,completed_at").single();
   if(error)throw error;
   return reply({approved:true,backup:data});
  }
  return reply({error:"Unsupported action."},400);
 }catch(error){console.error("Contribution operation failed:",error);return reply({error:error instanceof Error?error.message:"Contribution operation failed."},500);}
});