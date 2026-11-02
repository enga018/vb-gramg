// Payment/refund reconciliation support is deployed through the repository workflow.
import { createClient } from "npm:@supabase/supabase-js@2";
const corsHeaders={"Access-Control-Allow-Origin":"https://enga018.github.io","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Access-Control-Allow-Methods":"POST, OPTIONS","Content-Type":"application/json"};
function reply(body:Record<string,unknown>,status=200){return new Response(JSON.stringify(body),{status,headers:corsHeaders});}
function normalizeApplicantName(value:unknown){return String(value||"").normalize("NFKC").replace(/\s+/g," ").trim().toLocaleLowerCase();}
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
function matchActiveMisApplicant(byCard:Map<string,Record<string,string|null>[]>,jobCard:string,name:string){
 const target=normalizeApplicantName(name),matches=(byCard.get(jobCard)||[]).filter(a=>normalizeApplicantName(a.applicant_name)===target);
 return matches.length===1?matches[0]:null;
}
const periodFromNote=(note:string):string|null=>{const n=note.trim().toUpperCase();const months:Record<string,string>={JAN:"01",FEB:"02",MAR:"03",APR:"04",MAY:"05",JUN:"06",JUL:"07",AUG:"08",SEP:"09",OCT:"10",NOV:"11",DEC:"12"};const m=n.match(/^(JAN|FEB|MAR|APR|MAY|JUN|JUL|AUG|SEP|OCT|NOV|DEC)\s*26/);return m?`2026-${months[m[1]]}-01`:null;};
const isoDate=(ms:number):string=>new Date(ms).toISOString().slice(0,10);
function ftoEntryDate(rows:any[],deferred:boolean):string|null{if(deferred)return null;const dates=rows.filter(tx=>String(tx.status)==="processed"&&/^\d{4}-\d{2}-\d{2}$/.test(String(tx.processed_date||""))).map(tx=>String(tx.processed_date)).sort();return dates[0]||null;}
Deno.serve(async(req:Request)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:corsHeaders});
 if(req.method!=="POST")return reply({error:"Method not allowed"},405);
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
    // Exemption is authoritative: remove contribution-side records while preserving all FTO batches,
    // FTO transactions, and FTO status history. Clear the FK link before deleting ledger rows.
    const {error:extraDeleteError}=await admin.from("vbgramg_contribution_extras").delete().eq("job_card_number",jobCard);
    if(extraDeleteError)throw extraDeleteError;
    const {error:unlinkFtoError}=await admin.from("vbgramg_fto_transactions").update({ledger_entry_id:null}).eq("job_card_number",jobCard);
    if(unlinkFtoError)throw unlinkFtoError;
    const {error:ledgerDeleteError}=await admin.from("vbgramg_charge_ledger").delete().eq("job_card_number",jobCard);
    if(ledgerDeleteError)throw ledgerDeleteError;
    const {error:citizenDeleteError}=await admin.from("vbgramg_contribution_citizens").delete().eq("job_card_number",jobCard);
    if(citizenDeleteError)throw citizenDeleteError;
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
      const ftoRows=(ledgerRows||[]).filter(row=>String(row.period_id||"")===periodId&&/^FTO\\b/i.test(String(row.note||""))&&!/^FTO EXTRA\\b/i.test(String(row.note||"")));
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

  if(action==="list"){
   const all:Record<string,unknown>[]=[];
   for(let offset=0;;offset+=1000){const {data,error}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,applicant_name,applicant_number,applicant_unique_id,entry_type,amount,charge_period,period_id,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id").order("job_card_number",{ascending:true}).order("entry_date",{ascending:true}).range(offset,offset+999);if(error)throw error;all.push(...(data||[]));if(!data||data.length<1000||all.length>=20000)break;}
   const {data:exemptions,error:exemptionsError}=await admin.from("vbgramg_contribution_exemptions").select("job_card_number,note,created_at,updated_at").order("job_card_number",{ascending:true});if(exemptionsError)throw exemptionsError;
   const {data:imports,error:importError}=await admin.from("vbgramg_charge_imports").select("id,source_filename,charge_period,row_count,total_amount,status,completed_at").eq("status","complete").order("charge_period",{ascending:false}).limit(100);if(importError)throw importError;
   const {data:extras,error:extrasError}=await admin.from("vbgramg_contribution_extras").select("id,job_card_number,person_name,charge_period,period_id,amount,reason,ledger_entry_id,created_at,updated_at").order("charge_period",{ascending:false});if(extrasError)throw extrasError;
   const {data:misState,error:misStateError}=await admin.from("vbgramg_mis_state").select("active_import_id,row_count,source_filename").eq("singleton",true).maybeSingle();if(misStateError)throw misStateError;
   if(!misState?.active_import_id)throw new Error("There is no active MIS import. Load the active MIS before using the contribution table.");
   const misRows:Record<string,unknown>[]=[];
   for(let offset=0;;offset+=1000){const {data,error}=await admin.from("vbgramg_mis_rows").select("row_number,row_data").eq("import_id",misState.active_import_id).order("row_number",{ascending:true}).range(offset,offset+999);if(error)throw error;misRows.push(...(data||[]));if(!data||data.length<1000)break;}
   if(!misRows.length)throw new Error("The active MIS import contains no rows.");
   const header=Array.isArray(misRows[0].row_data)?(misRows[0].row_data as unknown[]).map(v=>String(v||"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim()):[];
   const col=(...names:string[])=>header.findIndex(v=>names.includes(v));
   const jcCol=col("job card number","jobcard number"),houseCol=col("head of household","head of household name"),nameCol=col("name of applicant","applicant name"),applicantNoCol=col("applicant no","applicant number"),uniqueIdCol=col("unique id","unique applicant id");
   if(jcCol<0||nameCol<0)throw new Error("The active MIS is missing Job Card Number or Name of Applicant columns.");
   const householdByCard=new Map<string,string>(),seenCards=new Set<string>(),applicantsByCard=new Map<string,Record<string,string|null>[]>();
   for(const record of misRows.slice(1)){const row=Array.isArray(record.row_data)?record.row_data as unknown[]:[];const jobCard=String(row[jcCol]||"").trim();if(!jobCard)continue;const applicant=String(row[nameCol]||"").trim();if(!applicant)continue;seenCards.add(jobCard);const household=String(houseCol>=0?row[houseCol]||"":"").trim();if(household&&!householdByCard.has(jobCard))householdByCard.set(jobCard,household);const item={applicant_name:applicant,applicant_number:applicantNoCol>=0?String(row[applicantNoCol]||"").trim()||null:null,applicant_unique_id:uniqueIdCol>=0?String(row[uniqueIdCol]||"").trim()||null:null};if(!applicantsByCard.has(jobCard))applicantsByCard.set(jobCard,[]);applicantsByCard.get(jobCard)!.push(item);}
   const citizens=[...seenCards].map(job_card_number=>({job_card_number,person_name:householdByCard.get(job_card_number)||"Household name unavailable"}));
   const chargeEntries=all.filter(r=>r.entry_type==="charge");
   if(chargeEntries.length){
    const entryById=new Map(chargeEntries.map(entry=>[String(entry.id),entry]));
    // Fetch only linked, charge-bearing FTO transactions in one request. The previous
    // implementation issued repeated UUID batches even when there were no linked FTO rows.
    const {data:txRows,error:txError}=await admin.from("vbgramg_fto_transactions").select("ledger_entry_id,person_name").not("ledger_entry_id","is",null).gt("calculated_charge",0).in("status",["blank","processed"]);
    if(txError)throw txError;
    const txNames=new Map<string,Set<string>>();
    for(const tx of txRows||[]){
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
   const {data:periodRows,error:periodRowsError}=await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,status,created_at").order("contribution_month",{ascending:false,nullsFirst:false}).order("created_at",{ascending:true});
   if(periodRowsError)throw periodRowsError;
   const paymentAllocations:Record<string,unknown>[]=[];
   for(let offset=0;;offset+=1000){
    const {data,error}=await admin.from("vbgramg_payment_allocations").select("id,transaction_id,period_id,job_card_number,amount,allocation_source,confidence,note,created_at,updated_at").order("created_at",{ascending:true}).range(offset,offset+999);
    if(error)throw error;
    paymentAllocations.push(...(data||[]));
    if(!data||data.length<1000)break;
   }
   const paymentRefundReconciliations:Record<string,unknown>[]=[];
   for(let offset=0;;offset+=1000){
    const {data,error}=await admin.from("vbgramg_payment_refund_reconciliations").select("id,payment_id,refund_id,job_card_number,amount,note,created_at").order("created_at",{ascending:true}).range(offset,offset+999);
    if(error)throw error;
    paymentRefundReconciliations.push(...(data||[]));
    if(!data||data.length<1000)break;
   }
   return reply({approved:true,role:approved.role,entries:all,imports:imports||[],extras:extras||[],citizens,periods:periodRows||[],payment_allocations:paymentAllocations||[],payment_refund_reconciliations:paymentRefundReconciliations||[],applicants_by_job_card:Object.fromEntries(applicantsByCard),exemptions:exemptions||[],active_mis_import_id:misState.active_import_id,active_mis_row_count:misRows.length});
  }
  if(action==="check-fto-duplicates"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can import FTO charges."},403);
   const period=String(body.charge_period||"").trim(),periodId=String(body.period_id||"").trim(),periodMatch=period.match(/^(\d{4})-(\d{2})-01$/);
   if(!periodMatch||Number(periodMatch[2])<1||Number(periodMatch[2])>12)return reply({error:"Choose a valid contribution month."},400);
   const periodDate=period;
   if(action==="check-fto-duplicates"){
    if(!periodId)return reply({error:"Select a specific contribution round."},400);
    const {data:selectedRound,error:selectedRoundError}=await admin.from("vbgramg_periods").select("id,contribution_month").eq("id",periodId).maybeSingle();
    if(selectedRoundError)throw selectedRoundError;
    if(!selectedRound||String(selectedRound.contribution_month||"")!==periodDate)return reply({error:"The selected contribution round does not match the month."},400);
    const cards=Array.isArray(body.job_cards)?[...new Set(body.job_cards.map((v:unknown)=>String(v||"").trim()).filter(Boolean))]:[];
    const referenceRows=Array.isArray(body.reference_rows)?body.reference_rows.map((v:Record<string,unknown>)=>({job_card_number:String(v.job_card_number||"").trim(),reference_numbers:Array.isArray(v.reference_numbers)?[...new Set(v.reference_numbers.map((r:unknown)=>String(r||"").trim()).filter(Boolean))]:[]})): [];
    if(cards.length>1000)return reply({error:"Check at most 1,000 job cards at a time."},400);
    if(!cards.length)return reply({approved:true,duplicates:[],duplicate_references:[]});
    const {data:existing,error:existingError}=await admin.from("vbgramg_charge_ledger").select("job_card_number,person_name,amount,is_deferred,note,reference_numbers,period_id").in("job_card_number",cards).eq("entry_type","charge").eq("charge_period",periodDate);
    if(existingError)throw existingError;
    const {data:knownLedger,error:knownLedgerError}=await admin.from("vbgramg_charge_ledger").select("job_card_number").in("job_card_number",cards);
    if(knownLedgerError)throw knownLedgerError;
    const {data:knownCitizens,error:knownCitizensError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number").in("job_card_number",cards);
    if(knownCitizensError)throw knownCitizensError;
    const known=new Set([...(knownLedger||[]).map(r=>String(r.job_card_number)),...(knownCitizens||[]).map(r=>String(r.job_card_number))]);
    const allReferences=[...new Set(referenceRows.flatMap(r=>r.reference_numbers))];
    const referenceMatches:Record<string,any>[]=[];
    if(allReferences.length){const {data,error}=await admin.from("vbgramg_charge_ledger").select("job_card_number,charge_period,period_id,note,reference_numbers").overlaps("reference_numbers",allReferences);if(error)throw error;referenceMatches.push(...(data||[]));}
    const duplicateMap=new Map<string,Set<string>>();
    for(const input of referenceRows){for(const reference of input.reference_numbers){for(const old of referenceMatches){if(!(old.reference_numbers||[]).includes(reference))continue;const oldRefs=old.reference_numbers||[];const sameReferenceSet=oldRefs.length>0&&oldRefs.every((r:string)=>input.reference_numbers.includes(r));const sameExistingCharge=String(old.job_card_number)===input.job_card_number&&String(old.period_id||"")===periodId&&String(old.charge_period||"")===periodDate&&/^FTO\b/i.test(String(old.note||""))&&sameReferenceSet;if(!sameExistingCharge){if(!duplicateMap.has(input.job_card_number))duplicateMap.set(input.job_card_number,new Set());duplicateMap.get(input.job_card_number)!.add(reference);}}}}
    return reply({approved:true,charge_period:periodDate,duplicates:[...new Map((existing||[]).filter(r=>(!r.period_id||String(r.period_id)===periodId)&&!(/^FTO\b/i.test(String(r.note||"")))).map(r=>[r.job_card_number,{job_card_number:r.job_card_number,person_name:r.person_name,amount:r.amount,is_deferred:r.is_deferred}])).values()],unknown_job_cards:cards.filter(card=>!known.has(card)),duplicate_references:[...duplicateMap].map(([job_card_number,refs])=>({job_card_number,reference_numbers:[...refs]}))});
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
     const {data,error}=await admin.from("vbgramg_fto_transactions").select("id,batch_id,reference_no,job_card_number,village_name,person_name,transaction_date,processed_date,amount_to_be_credited,credit_amount,calculated_charge,status,rejection_reason,last_seen_at,source_row,is_in_scope").in("batch_id",ids).eq("is_in_scope",true).order("job_card_number",{ascending:true}).order("reference_no",{ascending:true});
     if(error)throw error;
     transactions.push(...(data||[]));
    }
    const byBatch=new Map<string,Record<string,any>[]>();
    for(const tx of transactions){const id=String(tx.batch_id);if(!byBatch.has(id))byBatch.set(id,[]);byBatch.get(id)!.push(tx);}
    const result=batchRows.map((batch:Record<string,any>)=>{const rows=byBatch.get(String(batch.id))||[];const counts:Record<string,number>={blank:0,processed:0,rejected:0,other:0};for(const tx of rows){const state=String(tx.status||"other");counts[state]=(counts[state]||0)+1;}return {...batch,transaction_count:rows.length,status_counts:counts,transactions:rows};});
    return reply({approved:true,batches:result});
   }

  if(action==="get-fto-batch"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can access FTO tracking."},403);
   const ftoNumber=String(body.fto_number||"").trim().toUpperCase().slice(0,100);
   if(!ftoNumber)return reply({error:"Enter the FTO number first."},400);
   const {data:batch,error:batchError}=await admin.from("vbgramg_fto_batches").select("id,fto_number,contribution_period,ledger_charge_period,period_id,village_scope,first_imported_at,last_checked_at").eq("fto_number",ftoNumber).maybeSingle();
   if(batchError)throw batchError;
   return reply({approved:true,found:Boolean(batch),batch:batch||null});
  }

  if(action==="save-fto-applicant-matches"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can save FTO applicant matches."},403);
   const matches=body.matches;
   if(!Array.isArray(matches)||matches.length<1||matches.length>500)return reply({error:"Select at least one applicant match."},400);
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
   const {data:selectedRound,error:selectedRoundError}=await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,status").eq("id",periodId).maybeSingle();
   if(selectedRoundError)throw selectedRoundError;
   if(!selectedRound)return reply({error:"The selected contribution round was not found."},404);
   if(String(selectedRound.status||"open")!=="open")return reply({error:"This contribution round is closed. Reopen it before changing its extra charge."},409);
   const selectedMonth=String(selectedRound.contribution_month||selectedRound.period_date||"").slice(0,7);
   if(selectedMonth!==period.slice(0,7))return reply({error:"The selected contribution round does not match the chosen month."},400);
   const {data:known,error:knownError}=await admin.from("vbgramg_charge_ledger").select("person_name").eq("job_card_number",jobCard).limit(1).maybeSingle();
   if(knownError)throw knownError;
   const {data:citizen,error:citizenError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number,person_name").eq("job_card_number",jobCard).maybeSingle();
   if(citizenError)throw citizenError;
   if(!known&&!citizen)return reply({error:"This job card is not present in the contribution records."},404);
   const personName=String(known?.person_name||citizen?.person_name||"").trim()||jobCard;
   const note=("FTO EXTRA: "+reason).slice(0,200);
   const {data:oldExtra,error:oldExtraError}=await admin.from("vbgramg_contribution_extras").select("id,ledger_entry_id,created_by").eq("job_card_number",jobCard).eq("period_id",periodId).maybeSingle();
   if(oldExtraError)throw oldExtraError;
   let ledgerEntry:any=null;
   if(oldExtra?.ledger_entry_id){
    const {data:updated,error:updateError}=await admin.from("vbgramg_charge_ledger").update({person_name:personName,amount,entry_date:new Date().toISOString().slice(0,10),note,charge_period:period,period_id:periodId,is_deferred:false}).eq("id",oldExtra.ledger_entry_id).select("id,job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id").maybeSingle();
    if(updateError)throw updateError;
    ledgerEntry=updated;
   }
   if(!ledgerEntry){
    const {data:created,error:createError}=await admin.from("vbgramg_charge_ledger").insert({job_card_number:jobCard,person_name:personName,entry_type:"charge",amount,charge_period:period,period_id:periodId,entry_date:new Date().toISOString().slice(0,10),note,is_deferred:false,created_by:authData.user.id}).select("id,job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id").single();
    if(createError)throw createError;
    ledgerEntry=created;
   }
   const {data:extra,error:extraError}=await admin.from("vbgramg_contribution_extras").upsert({job_card_number:jobCard,person_name:personName,charge_period:period,period_id:periodId,amount,reason,ledger_entry_id:ledgerEntry.id,created_by:oldExtra?.created_by||authData.user.id,updated_by:authData.user.id,updated_at:new Date().toISOString()},{onConflict:"job_card_number,period_id"}).select("id,job_card_number,person_name,charge_period,period_id,amount,reason,ledger_entry_id,created_at,updated_at").single();
   if(extraError)throw extraError;
   return reply({approved:true,extra,entry:ledgerEntry,updated:Boolean(oldExtra)});
  }

  if(action==="edit-ledger-entry"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can edit ledger entries."},403);
   const id=String(body.id||"").trim(),amount=Number(body.amount),entryDate=String(body.entry_date||""),note=String(body.note??"").trim().slice(0,200);
   if(!id)return reply({error:"Ledger entry ID is required."},400);
   if(!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Enter a valid positive amount."},400);
   if(!/^\d{4}-\d{2}-\d{2}$/.test(entryDate)||Number.isNaN(Date.parse(entryDate)))return reply({error:"Enter a valid transaction date."},400);
   const {data:old,error:oldError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note,import_id,created_by,created_at,is_deferred,legacy_entry_id,source_created_at_ms").eq("id",id).maybeSingle();
   if(oldError)throw oldError;if(!old)return reply({error:"Ledger entry was not found."},404);
   const type=String(old.entry_type||"");
   if(type==="payment"){
    const {data:existingAllocations,error:allocationError}=await admin.from("vbgramg_payment_allocations").select("amount").eq("transaction_id",id);
    if(allocationError)throw allocationError;
    const allocatedTotal=(existingAllocations||[]).reduce((sum,row)=>sum+Math.max(0,Number(row.amount)||0),0);
    if(allocatedTotal>amount+0.001)return reply({error:"This payment has "+allocatedTotal.toFixed(2)+" allocated. Review or reduce its period allocations before lowering the payment amount."},409);
   }
   const isLegacyReturn=type==="charge"&&String(old.note||"").trim().toLowerCase()==="return";
   if(!["charge","payment","refund","charge_waiver","other_charge","return","forgive","sanitationFee"].includes(type))return reply({error:"This transaction type cannot be edited here."},400);
   if(type==="charge"&&!isLegacyReturn&&/^FTO\b/i.test(String(old.note||""))&&!/^FTO\b/i.test(note))return reply({error:"FTO-imported charges must keep the FTO marker in their note."},400);
   if(isLegacyReturn&&note.toLowerCase()!=="return")return reply({error:"Keep the note as Return for this legacy entry."},400);
   let chargePeriod=old.charge_period;
   if(type==="charge"&&!isLegacyReturn){
    chargePeriod=String(body.charge_period||"").trim();
    if(!/^\d{4}-\d{2}-01$/.test(chargePeriod)||Number(chargePeriod.slice(5,7))<1||Number(chargePeriod.slice(5,7))>12)return reply({error:"Choose a valid charge month."},400);
    if(String(old.period_id||"")&&chargePeriod!==String(old.charge_period||""))return reply({error:"This charge belongs to a specific contribution round. Change its round through the FTO period reassignment workflow, not by editing the month here."},409);
    if(/^FTO\b/i.test(String(old.note||""))&&chargePeriod!==String(old.charge_period||""))return reply({error:"FTO-imported charges must be reassigned through the FTO period workflow so the batch and ledger remain synchronized."},409);
   }
   const isDeferred=type==="charge"&&!isLegacyReturn?Boolean(body.is_deferred):Boolean(old.is_deferred);
   const patch:Record<string,unknown>={amount,entry_date:entryDate,note:note||null};
   if(type==="charge"&&!isLegacyReturn){patch.charge_period=chargePeriod;patch.is_deferred=isDeferred;}
   const {data:updated,error:updateError}=await admin.from("vbgramg_charge_ledger").update(patch).eq("id",id).select("id,job_card_number,person_name,entry_type,amount,charge_period,period_id,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id").single();
   if(updateError)throw updateError;
   const {error:auditError}=await admin.from("vbgramg_ledger_audit").insert({ledger_entry_id:id,job_card_number:old.job_card_number,action:"edit",actor_user_id:authData.user.id,actor_email:email,before_data:old,after_data:updated});
   if(auditError)throw auditError;
   return reply({approved:true,entry:updated});
  }
  if(action==="add-waiver"||action==="add-return"||action==="pay-in-full"){
   const jobCard=String(body.job_card_number||"").trim();
   if(!jobCard)return reply({error:"Job card number is required."},400);
   if(action!=="pay-in-full"&&approved.role!=="admin")return reply({error:"Only an approved administrator can record waivers or returns."},403);
   const requestedAmount=Number(body.amount),entryDate=String(body.entry_date||new Date().toISOString().slice(0,10));
   const note=String(body.note||(action==="add-waiver"?"Waiver":action==="add-return"?"Return":"Pay in full")).trim().slice(0,200);
   if(!/^\d{4}-\d{2}-\d{2}$/.test(entryDate)||Number.isNaN(Date.parse(entryDate)))return reply({error:"Enter a valid transaction date."},400);
   const {data:ledger,error:ledgerError}=await admin.from("vbgramg_charge_ledger").select("id,entry_type,amount,note,is_deferred,charge_period,person_name").eq("job_card_number",jobCard);
   if(ledgerError)throw ledgerError;
   if(!ledger||!ledger.length)return reply({error:"Job card not found in the contribution ledger."},404);
   let charges=0,paid=0,returns=0,waived=0;
   for(const e of ledger){const n=Math.max(0,Number(e.amount)||0),t=String(e.entry_type||"");
    if(t==="payment")paid+=n;
    else if(t==="refund"||t==="return"||(t==="charge"&&String(e.note||"").trim().toLowerCase()==="return"))returns+=n;
    else if(t==="charge_waiver"||t==="forgive")waived+=n;
    else if((t==="charge"||t==="other_charge"||t==="sanitationFee")&&!e.is_deferred)charges+=n;
   }
   const balance=charges-Math.min(waived,charges)-paid+returns;
   let amount=requestedAmount,type="",finalNote=note;
   if(action==="pay-in-full"){amount=Math.max(0,Number(balance.toFixed(2)));type="payment";finalNote="Cash";}
   else if(action==="add-waiver"){type="charge_waiver";if(!Number.isFinite(amount)||amount<=0||amount>Math.max(0,balance)+0.001)return reply({error:"Waiver must be positive and cannot exceed the current outstanding balance."},400);}
   else {type="refund";if(!Number.isFinite(amount)||amount<=0||amount>Math.max(0,paid-returns)+0.001)return reply({error:"Return amount must be positive and cannot exceed payments less previous returns."},400);}
   if(!Number.isFinite(amount)||amount<=0)return reply({error:action==="pay-in-full"?"There is no outstanding balance to pay in full.":"Enter a valid positive amount."},400);
   const {data:inserted,error:insertError}=await admin.from("vbgramg_charge_ledger").insert({job_card_number:jobCard,person_name:ledger[0].person_name,entry_type:type,amount,entry_date:entryDate,note:finalNote,created_by:authData.user.id}).select("id,job_card_number,person_name,entry_type,amount,charge_period,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id").single();
   if(insertError)throw insertError;
   const {error:auditError}=await admin.from("vbgramg_ledger_audit").insert({ledger_entry_id:inserted.id,job_card_number:jobCard,action:action==="pay-in-full"?"pay-in-full":action==="add-waiver"?"waiver":"return",actor_user_id:authData.user.id,actor_email:email,before_data:{balance},after_data:inserted});
   if(auditError)throw auditError;
   return reply({approved:true,entry:inserted,balance_before:balance});
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
   const jobCards=normalized.map(x=>x.job_card_number);
   const {data:known,error:knownError}=await admin.from("vbgramg_charge_ledger").select("job_card_number,person_name").eq("entry_type","charge").in("job_card_number",jobCards);
   if(knownError)throw knownError;
   const people=new Map<string,string>();
   for(const row of known||[])if(!people.has(String(row.job_card_number)))people.set(String(row.job_card_number),String(row.person_name||""));
   const missing=jobCards.filter(card=>!people.has(card));
   if(missing.length)return reply({error:"No existing contribution charge found for: "+missing.join(", ")},400);
   const inserts=normalized.map(row=>({job_card_number:row.job_card_number,person_name:people.get(row.job_card_number)||"",entry_type:"payment",amount:row.amount,entry_date:entryDate,note:"Bank",created_by:authData.user.id}));
   const {data:inserted,error:insertError}=await admin.from("vbgramg_charge_ledger").insert(inserts).select("id,job_card_number,person_name,entry_type,amount,charge_period,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id");
   if(insertError)throw insertError;
   const auditRows=(inserted||[]).map((entry:Record<string,unknown>)=>({ledger_entry_id:entry.id,job_card_number:entry.job_card_number,action:"bulk-bank-payment",actor_user_id:authData.user.id,actor_email:email,before_data:null,after_data:entry}));
   const {error:auditError}=await admin.from("vbgramg_ledger_audit").insert(auditRows);
   if(auditError)throw auditError;
   const total=normalized.reduce((sum,row)=>sum+row.amount,0);
   return reply({approved:true,role:approved.role,entries:inserted||[],count:(inserted||[]).length,total_amount:total,method:"Bank"});
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
   const jobCard=String(body.job_card_number||"").trim(),amount=Number(body.amount),entryDate=String(body.entry_date||""),note="Cash";
   if(!jobCard||!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Enter a valid job card number and positive payment amount."},400);
   if(!/^\d{4}-\d{2}-\d{2}$/.test(entryDate)||Number.isNaN(Date.parse(entryDate)))return reply({error:"Enter a valid payment date."},400);
   const {data:charge,error:chargeError}=await admin.from("vbgramg_charge_ledger").select("person_name").eq("job_card_number",jobCard).eq("entry_type","charge").limit(1).maybeSingle();if(chargeError)throw chargeError;if(!charge)return reply({error:"Job card not found in the contribution ledger."},404);
   const {data:inserted,error:insertError}=await admin.from("vbgramg_charge_ledger").insert({job_card_number:jobCard,person_name:charge.person_name,entry_type:"payment",amount,entry_date:entryDate,note:note||"Cash",created_by:authData.user.id}).select("id,job_card_number,person_name,entry_type,amount,charge_period,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id").single();if(insertError)throw insertError;return reply({approved:true,role:approved.role,entry:inserted});
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