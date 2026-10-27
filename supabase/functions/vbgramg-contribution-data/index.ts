import "jsr:@supabase/functions-js/edge-runtime.d.ts";
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
   const {data:extras,error:extrasError}=await admin.from("vbgramg_contribution_extras").select("id,job_card_number,person_name,charge_period,amount,reason,ledger_entry_id,created_at,updated_at").order("charge_period",{ascending:false});if(extrasError)throw extrasError;
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
    const chunks:string[][]=[];
    // Keep PostgREST URLs short: large UUID IN-lists can exceed request limits.
    for(let offset=0;offset<chargeEntries.length;offset+=100)chunks.push(chargeEntries.slice(offset,offset+100).map(entry=>String(entry.id)));
    // Run only a few small batches concurrently to avoid oversized requests and connection spikes.
    for(let wave=0;wave<chunks.length;wave+=5){
     const attributionBatches=await Promise.all(chunks.slice(wave,wave+5).map(async ids=>{
      const {data:txRows,error:txError}=await admin.from("vbgramg_fto_transactions").select("ledger_entry_id,person_name").in("ledger_entry_id",ids).gt("calculated_charge",0).in("status",["blank","processed"]);
      if(txError)throw txError;
      const txNames=new Map<string,Set<string>>();
      for(const tx of txRows||[]){const id=String(tx.ledger_entry_id||""),name=String(tx.person_name||"").trim();if(!id||!name)continue;if(!txNames.has(id))txNames.set(id,new Set());txNames.get(id)!.add(name);}
      return txNames;
     }));
     for(const txNames of attributionBatches){
      for(const [id,names] of txNames){
       const entry=entryById.get(id);
       if(!entry||names.size!==1)continue;
       const match=matchActiveMisApplicant(applicantsByCard,String(entry.job_card_number),[...names][0]);
       if(match){entry.applicant_name=match.applicant_name;entry.applicant_number=match.applicant_number;entry.applicant_unique_id=match.applicant_unique_id;entry.applicant_attribution="matched_from_fto";}
      }
     }
    }
   }
   const {data:periodRows,error:periodRowsError}=await admin.from("vbgramg_periods").select("id,period_name,period_date,contribution_month,created_at").order("contribution_month",{ascending:false,nullsFirst:false}).order("created_at",{ascending:true});
   if(periodRowsError)throw periodRowsError;
   return reply({approved:true,role:approved.role,entries:all,imports:imports||[],extras:extras||[],citizens,periods:periodRows||[],applicants_by_job_card:Object.fromEntries(applicantsByCard),exemptions:exemptions||[],active_mis_import_id:misState.active_import_id,active_mis_row_count:misRows.length});
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
   const activeMisApplicants=await loadActiveMisApplicants(admin);
   const seen=new Set<string>(),rowsToSave:Record<string,any>[]=[];
   for(const item of matches){
    const jobCard=String(item?.job_card_number||"").trim(),ftoName=String(item?.fto_name||"").trim(),normalizedName=normalizeApplicantName(ftoName),uniqueId=String(item?.applicant_unique_id||"").trim();
    if(!jobCard||!ftoName||!normalizedName||!uniqueId)return reply({error:"Each manual match needs an FTO name, job card, and selected MIS applicant."},400);
    const key=jobCard+"::"+normalizedName;
    if(seen.has(key))return reply({error:"The same FTO name was submitted more than once."},400);
    seen.add(key);
    const candidates=(activeMisApplicants.get(jobCard)||[]).filter(a=>String(a.applicant_unique_id||"")===uniqueId);
    if(candidates.length!==1)return reply({error:"A selected applicant is no longer uniquely available in active MIS for job card "+jobCard+". Refresh the FTO review and select again."},409);
    const applicant=candidates[0];
    rowsToSave.push({job_card_number:jobCard,normalized_fto_name:normalizedName,fto_name:ftoName,applicant_unique_id:uniqueId,applicant_number:applicant.applicant_number,applicant_name:applicant.applicant_name,confirmed_by:authData.user.id,updated_at:new Date().toISOString()});
   }
   const {error:saveError}=await admin.from("vbgramg_fto_applicant_matches").upsert(rowsToSave,{onConflict:"job_card_number,normalized_fto_name"});
   if(saveError)throw saveError;
   return reply({approved:true,saved:rowsToSave.length});
  }

  if(action==="sync-fto-batch"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can synchronize FTO transactions."},403);
   const ftoNumber=String(body.fto_number||"").trim().toUpperCase().slice(0,100);
   let periodId=String(body.period_id||"").trim();
   const contributionPeriod=String(body.contribution_period||"").trim().slice(0,100);
   const chargePeriod=String(body.charge_period||"").trim();
   const periodMatch=chargePeriod.match(/^(\d{4})-(\d{2})-01$/);
   const villageScope="NEW SERCHHIP North";
   const rows=body.rows;
   if(!ftoNumber)return reply({error:"Enter the FTO number shown on the government page."},400);
   if(!contributionPeriod)return reply({error:"Select a contribution period from the shared list."},400);
   if(!periodMatch||Number(periodMatch[2])<1||Number(periodMatch[2])>12)return reply({error:"Enter a recognizable month and year, such as August 2026."},400);
   if(!Array.isArray(rows)||rows.length<1||rows.length>5000)return reply({error:"The pasted FTO must contain 1–5,000 transaction rows."},400);
   const sourceSha=String(body.source_sha256||"").toLowerCase();
   const sourceFilename=("FTO-"+ftoNumber).slice(0,255);
   if(!/^[a-f0-9]{64}$/.test(sourceSha))return reply({error:"FTO synchronization identity is missing. Reload the preview and try again."},400);
   const reviewed=Array.isArray(body.reviewed_duplicates)?new Set(body.reviewed_duplicates.map((v:unknown)=>String(v||"").trim())):new Set<string>();
   const reviewedNew=Array.isArray(body.reviewed_new_job_cards)?new Set(body.reviewed_new_job_cards.map((v:unknown)=>String(v||"").trim())):new Set<string>();
   const normVillage=(v:unknown)=>String(v||"").toUpperCase().replace(/[^A-Z0-9 ]/g," ").replace(/\s+/g," ").trim();
    const rowsSeen=rows.length;
    const excludedOtherVillage=rows.filter((raw:Record<string,any>)=>normVillage(raw?.village_name)!==normVillage(villageScope)).length;
    const localInputRows=rows.filter((raw:Record<string,any>)=>normVillage(raw?.village_name)===normVillage(villageScope));
    if(!localInputRows.length)return reply({error:"No transactions for NEW SERCHHIP North were found. Nothing was imported."},400);
   const normalized:Record<string,any>[]=[];
   const seenReferences=new Map<string,string>();
   for(const raw of rows){
    const referenceNo=String(raw.reference_no||"").trim().slice(0,200);
    const jobCard=String(raw.job_card_number||"").trim().toUpperCase().slice(0,100);
    const villageName=String(raw.village_name||"").trim().slice(0,150);
    const personName=String(raw.person_name||"").trim().slice(0,200);
    const status=String(raw.status||"").trim().toLowerCase();
    const creditAmount=Number(raw.credit_amount);
    const amountToCredit=Number(raw.amount_to_be_credited);
    const calculatedCharge=Number(raw.calculated_charge);
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
      is_in_scope:normVillage(villageName)===normVillage(villageScope),
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
   const incomingCards=[...new Set(normalized.filter(r=>r.is_in_scope).map(r=>String(r.job_card_number)))];
   const {data:exemptionRows,error:exemptionError}=await admin.from("vbgramg_contribution_exemptions").select("job_card_number");
   if(exemptionError)throw exemptionError;
   const exemptCards=new Set((exemptionRows||[]).map(r=>String(r.job_card_number)));
   const chargeCandidateRows=normalized.filter(r=>r.is_in_scope&&!exemptCards.has(String(r.job_card_number))&&["blank","processed"].includes(String(r.status))&&Number(r.calculated_charge||0)>0);
   const chargeCandidateCards=[...new Set(chargeCandidateRows.map(r=>String(r.job_card_number)))];
   const incomingRefs=chargeCandidateRows.map(r=>String(r.reference_no));
   const activeMisApplicants=await loadActiveMisApplicants(admin);
   const {data:savedMatchRows,error:savedMatchError}=chargeCandidateCards.length
    ?await admin.from("vbgramg_fto_applicant_matches").select("job_card_number,normalized_fto_name,applicant_unique_id").in("job_card_number",chargeCandidateCards)
    :{data:[],error:null};
   if(savedMatchError)throw savedMatchError;
   const savedMatchMap=new Map((savedMatchRows||[]).map((m:Record<string,any>)=>[String(m.job_card_number)+"::"+String(m.normalized_fto_name),m]));
   const resolveFtoApplicant=(row:Record<string,any>)=>{
    const card=String(row.job_card_number),normalizedName=normalizeApplicantName(row.person_name);
    const saved=savedMatchMap.get(card+"::"+normalizedName) as Record<string,any>|undefined;
    if(saved){
     const mapped=(activeMisApplicants.get(card)||[]).filter(a=>String(a.applicant_unique_id||"")===String(saved.applicant_unique_id));
     if(mapped.length===1)return mapped[0];
    }
    return matchActiveMisApplicant(activeMisApplicants,card,String(row.person_name));
   };
   const manualReviewMap=new Map<string,Record<string,any>>();
   for(const row of chargeCandidateRows){
    if(resolveFtoApplicant(row))continue;
    const card=String(row.job_card_number),name=String(row.person_name),normalizedName=normalizeApplicantName(name),key=card+"::"+normalizedName;
    if(!manualReviewMap.has(key))manualReviewMap.set(key,{job_card_number:card,fto_name:name,normalized_fto_name:normalizedName,candidates:(activeMisApplicants.get(card)||[]).filter(a=>String(a.applicant_unique_id||"").trim())});
   }
   if(manualReviewMap.size)return reply({needs_manual_review:true,error:"Some FTO names need manual matching to an active MIS applicant. No FTO transactions or contribution charges were changed. Select the correct applicant for each item, save the matches, then synchronize again.",manual_review:[...manualReviewMap.values()]});
   const incomingApplicantsByCard=new Map<string,Set<string>>();
   const matchedApplicantByCard=new Map<string,Record<string,string|null>>();
   for(const row of chargeCandidateRows){
    const card=String(row.job_card_number),applicant=resolveFtoApplicant(row),id=String(applicant?.applicant_unique_id||"");
    if(!incomingApplicantsByCard.has(card))incomingApplicantsByCard.set(card,new Set());
    if(id)incomingApplicantsByCard.get(card)!.add(id);
    if(applicant&&!matchedApplicantByCard.has(card))matchedApplicantByCard.set(card,applicant);
   }
   const multiApplicantCards=[...incomingApplicantsByCard].filter(([,ids])=>ids.size>1).map(([job_card_number])=>job_card_number);
   if(multiApplicantCards.length)return reply({error:"More than one MIS applicant has a charge in the same job card and contribution period. This violates the existing FTO rule; no charge was synchronized.",conflicting_job_cards:multiApplicantCards},409);
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
    const {data:ledgerRefMatches,error:ledgerRefError}=await admin.from("vbgramg_charge_ledger").select("job_card_number,charge_period,period_id,note,reference_numbers").overlaps("reference_numbers",incomingRefs);
    if(ledgerRefError)throw ledgerRefError;
    for(const input of chargeCandidateRows){
     for(const old of ledgerRefMatches||[]){
      if(!(old.reference_numbers||[]).includes(String(input.reference_no)))continue;
      const sameFtoLedger=String(old.job_card_number)===String(input.job_card_number)&&String(old.period_id||"")===periodId&&String(old.charge_period||"")===chargePeriod&&/^FTO\\b/i.test(String(old.note||""));
      if(!sameFtoLedger)return reply({error:"Reference number "+input.reference_no+" already exists on a different or non-FTO ledger charge. Review the existing record before synchronizing.",duplicate_references:[{job_card_number:input.job_card_number,reference_numbers:[input.reference_no]}]},409);
     }
    }
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
    const {data:existingLedger,error:existingLedgerError}=await admin.from("vbgramg_charge_ledger").select("job_card_number,person_name,amount,is_deferred,note,reference_numbers,period_id").in("job_card_number",chargeCandidateCards).eq("entry_type","charge").eq("charge_period",chargePeriod);
    if(existingLedgerError)throw existingLedgerError;
    const nonFto=[...new Map((existingLedger||[]).filter(r=>(!r.period_id||String(r.period_id)===periodId)&&!/^FTO\b/i.test(String(r.note||""))).map(r=>[String(r.job_card_number),{job_card_number:r.job_card_number,person_name:r.person_name,amount:r.amount,is_deferred:r.is_deferred}])).values()];
    const unreviewed=nonFto.filter(r=>!reviewed.has(String(r.job_card_number)));
    if(unreviewed.length)return reply({error:"Some local job cards already have non-FTO charges for this period. Review each flagged job card before continuing.",duplicates:unreviewed},409);
    const {data:knownLedger,error:knownLedgerError}=await admin.from("vbgramg_charge_ledger").select("job_card_number").in("job_card_number",chargeCandidateCards);
    if(knownLedgerError)throw knownLedgerError;
    const {data:knownCitizens,error:knownCitizensError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number").in("job_card_number",chargeCandidateCards);
    if(knownCitizensError)throw knownCitizensError;
    const known=new Set([...(knownLedger||[]).map(r=>String(r.job_card_number)),...(knownCitizens||[]).map(r=>String(r.job_card_number))]);
    const unverified=chargeCandidateCards.filter(card=>!known.has(card)&&!reviewedNew.has(card));
    if(unverified.length)return reply({error:"Some local job cards are not in the existing contribution records. Verify them before importing.",unknown_job_cards:unverified},409);
   }
   let batchId=String(batchOld?.id||"");
   if(!batchOld){
    const {data:created,error:createError}=await admin.from("vbgramg_fto_batches").insert({fto_number:ftoNumber,period_id:periodId,contribution_period:contributionPeriod,ledger_charge_period:chargePeriod,village_scope:villageScope,created_by:authData.user.id}).select("id").single();
    if(createError)throw createError;
    batchId=String(created.id);
   } else if(String(batchOld.period_id||"")!==periodId){
    const {error:periodLinkError}=await admin.from("vbgramg_fto_batches").update({period_id:periodId}).eq("id",batchId);
    if(periodLinkError)throw periodLinkError;
   }
   const {data:oldBatchTransactions,error:oldBatchTransactionsError}=await admin.from("vbgramg_fto_transactions").select("id,reference_no,status,calculated_charge,job_card_number,processed_date").eq("batch_id",batchId);
   if(oldBatchTransactionsError)throw oldBatchTransactionsError;
   const oldByRef=new Map((oldBatchTransactions||[]).map(r=>[String(r.reference_no),r]));
   const nowIso=new Date().toISOString();
   for(const row of normalized){
    const old=oldByRef.get(String(row.reference_no));
    if(old&&(String(old.status)!==String(row.status)||Number(old.calculated_charge||0)!==Number(row.calculated_charge||0)||String(old.processed_date||"")!==String(row.processed_date||""))){
     const {error:historyError}=await admin.from("vbgramg_fto_status_history").insert({
      transaction_id:old.id,old_status:old.status,new_status:row.status,
      old_calculated_charge:Number(old.calculated_charge||0),new_calculated_charge:Number(row.calculated_charge||0),
      old_processed_date:old.processed_date||null,new_processed_date:row.processed_date||null,
      changed_by:authData.user.id,fto_number:ftoNumber,reference_no:row.reference_no,
      note:"Status, processed date, or calculated charge changed during FTO synchronization"
     });
     if(historyError)throw historyError;
    }
    const transactionPayload={...row,batch_id:batchId,last_seen_at:nowIso,updated_at:nowIso};
    if(old){
     const {error:updateError}=await admin.from("vbgramg_fto_transactions").update(transactionPayload).eq("id",old.id);
     if(updateError)throw updateError;
    }else{
     const {error:insertError}=await admin.from("vbgramg_fto_transactions").insert(transactionPayload);
     if(insertError)throw insertError;
     const inserted=(await admin.from("vbgramg_fto_transactions").select("id").eq("batch_id",batchId).eq("reference_no",row.reference_no).maybeSingle());
     if(inserted.error)throw inserted.error;
     const {error:historyError}=await admin.from("vbgramg_fto_status_history").insert({
      transaction_id:inserted.data.id,old_status:null,new_status:row.status,
      old_calculated_charge:null,new_calculated_charge:Number(row.calculated_charge||0),
      old_processed_date:null,new_processed_date:row.processed_date||null,
      changed_by:authData.user.id,fto_number:ftoNumber,reference_no:row.reference_no,
      note:"Transaction first recorded from pasted FTO"
     });
     if(historyError)throw historyError;
    }
   }
   const {error:batchUpdateError}=await admin.from("vbgramg_fto_batches").update({last_checked_at:nowIso,last_source_sha256:sourceSha}).eq("id",batchId);
   if(batchUpdateError)throw batchUpdateError;
   const {data:priorImport,error:priorImportError}=await admin.from("vbgramg_charge_imports").select("id,status").eq("source_sha256",sourceSha).maybeSingle();
   if(priorImportError)throw priorImportError;
   let importId=String(priorImport?.id||"");
   if(!priorImport){
    const {data:created,error:createError}=await admin.from("vbgramg_charge_imports").insert({
     source_filename:sourceFilename,source_sha256:sourceSha,charge_period:chargePeriod,
     row_count:incomingCards.length,total_amount:0,status:"staging",imported_by:authData.user.id,
     notes:("FTO sync "+ftoNumber+"; period label: "+contributionPeriod).slice(0,500)
    }).select("id").single();
    if(createError)throw createError;importId=String(created.id);
   }
   let insertedCount=0,updatedCount=0,deletedCount=0;
   const affectedCards=incomingCards;
   if(affectedCards.length){
    const {data:trackedRows,error:trackedError}=await admin.from("vbgramg_fto_transactions").select("id,batch_id,reference_no,job_card_number,calculated_charge,status,processed_date,is_in_scope,last_seen_at,ledger_entry_id").in("job_card_number",affectedCards);
    if(trackedError)throw trackedError;
    const trackBatchIds=[...new Set((trackedRows||[]).map(r=>String(r.batch_id)))];
    let trackBatches:Record<string,any>[]=[];
    if(trackBatchIds.length){const {data,error}=await admin.from("vbgramg_fto_batches").select("id,ledger_charge_period,period_id").in("id",trackBatchIds);if(error)throw error;trackBatches=data||[];}
     const trackPeriod=new Map(trackBatches.map(r=>[String(r.id),{month:String(r.ledger_charge_period||""),periodId:String(r.period_id||"")}]));
     const relevant=(trackedRows||[]).filter(r=>{const p=trackPeriod.get(String(r.batch_id));return p?.month===chargePeriod&&p.periodId===periodId&&r.is_in_scope===true;});
    const latestByReference=new Map<string,Record<string,any>>();
    for(const tx of relevant){const key=String(tx.reference_no),old=latestByReference.get(key);if(!old||String(tx.last_seen_at)>String(old.last_seen_at))latestByReference.set(key,tx);}
    const txByCard=new Map<string,Record<string,any>[]>();
    for(const tx of latestByReference.values()){const card=String(tx.job_card_number);if(!txByCard.has(card))txByCard.set(card,[]);txByCard.get(card)!.push(tx);}
    const {data:ledgerRows,error:ledgerRowsError}=await admin.from("vbgramg_charge_ledger").select("id,job_card_number,person_name,amount,is_deferred,note,reference_numbers,import_id,period_id").in("job_card_number",affectedCards).eq("entry_type","charge").eq("charge_period",chargePeriod);
    if(ledgerRowsError)throw ledgerRowsError;
    for(const card of affectedCards){
     if(exemptCards.has(card))continue;
     const txs=txByCard.get(card)||[];
     const active=txs.filter(tx=>["blank","processed"].includes(String(tx.status))&&Number(tx.calculated_charge||0)>0);
     const refs=[...new Set(active.map(tx=>String(tx.reference_no)))];
     const amount=Number(active.reduce((sum,tx)=>sum+Number(tx.calculated_charge||0),0).toFixed(2));
      const ftoRows=(ledgerRows||[]).filter(r=>String(r.job_card_number)===card&&/^FTO\b/i.test(String(r.note||""))&&!/^FTO EXTRA\b/i.test(String(r.note||""))&&(String(r.period_id||"")===periodId||(!r.period_id&&(r.reference_numbers||[]).some((ref:string)=>refs.includes(String(ref))))));
      const keeper=ftoRows.find(r=>(r.reference_numbers||[]).some((ref:string)=>refs.includes(String(ref))))||ftoRows[0]||null;
     if(amount>0){
      const isDeferred=active.every(tx=>String(tx.status)==="blank"),entryDate=ftoEntryDate(active,isDeferred);
      const activeApplicantName=String((normalized.find(r=>String(r.job_card_number)===card&&r.is_in_scope)?.person_name)||"");
      const applicantMatch=matchedApplicantByCard.get(card)||null;
      const name=activeApplicantName||keeper?.person_name||"";
      const applicantFields=applicantMatch?{applicant_name:applicantMatch.applicant_name,applicant_number:applicantMatch.applicant_number,applicant_unique_id:applicantMatch.applicant_unique_id}:{};
      let ledgerId="";
      if(keeper){
       const {error:updateLedgerError}=await admin.from("vbgramg_charge_ledger").update({period_id:periodId,person_name:name||keeper.person_name,amount,is_deferred:isDeferred,entry_date:entryDate,reference_numbers:refs,note:"FTO import",...applicantFields}).eq("id",keeper.id);
       if(updateLedgerError)throw updateLedgerError;ledgerId=String(keeper.id);updatedCount++;
      }else{
       const {data:newLedger,error:insertLedgerError}=await admin.from("vbgramg_charge_ledger").insert({
        job_card_number:card,person_name:name||"Name needs review",...applicantFields,entry_type:"charge",amount,
        charge_period:chargePeriod,period_id:periodId,entry_date:entryDate,note:"FTO import",
        reference_numbers:refs,is_deferred:isDeferred,created_by:authData.user.id,import_id:importId
       }).select("id").single();
       if(insertLedgerError)throw insertLedgerError;ledgerId=String(newLedger.id);insertedCount++;
      }
      const ids=txs.map(tx=>String(tx.id));
      if(ids.length){const {error:linkError}=await admin.from("vbgramg_fto_transactions").update({ledger_entry_id:ledgerId}).in("id",ids);if(linkError)throw linkError;}
     }else{
      const trackedRefs=new Set(txs.map(tx=>String(tx.reference_no)));
      const deletable=ftoRows.filter(r=>{
       const oldRefs=Array.isArray(r.reference_numbers)?r.reference_numbers.map(String):[];
       return oldRefs.length>0&&oldRefs.every((ref:string)=>trackedRefs.has(ref))&&txs.length>0&&txs.every(tx=>String(tx.status)==="rejected")&&oldRefs.some((ref:string)=>txs.some(tx=>String(tx.reference_no)===ref&&String(tx.status)==="rejected"));
      });
      if(deletable.length){
       const {error:deleteError}=await admin.from("vbgramg_charge_ledger").delete().in("id",deletable.map(r=>r.id));
       if(deleteError)throw deleteError;deletedCount+=deletable.length;
       const ids=txs.map(tx=>String(tx.id));
       if(ids.length){const {error:unlinkError}=await admin.from("vbgramg_fto_transactions").update({ledger_entry_id:null}).in("id",ids);if(unlinkError)throw unlinkError;}
      }
     }
    }
   }
   const totalAmount=Number(normalized.filter(r=>r.is_in_scope&&!exemptCards.has(String(r.job_card_number))&&["blank","processed"].includes(String(r.status))).reduce((sum,r)=>sum+Number(r.calculated_charge||0),0).toFixed(2));
   const {error:completeError}=await admin.from("vbgramg_charge_imports").update({status:"complete",completed_at:new Date().toISOString(),row_count:incomingCards.length,total_amount:totalAmount,notes:("FTO sync "+ftoNumber+"; period label: "+contributionPeriod).slice(0,500)}).eq("id",importId);
   if(completeError)throw completeError;
   return reply({approved:true,fto_number:ftoNumber,contribution_period:contributionPeriod,charge_period:chargePeriod,rows_seen:rowsSeen,local_transactions:normalized.length,excluded_other_village:excludedOtherVillage,inserted:insertedCount,updated:updatedCount,deleted:deletedCount,total_amount:totalAmount,batch_id:batchId});
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
   const activeMisApplicants=await loadActiveMisApplicants(admin);
   const statusCards=[...new Set(normalized.map(row=>String(row.job_card_number)))];
   const {data:statusMatchRows,error:statusMatchError}=statusCards.length
    ?await admin.from("vbgramg_fto_applicant_matches").select("job_card_number,normalized_fto_name,applicant_unique_id").in("job_card_number",statusCards)
    :{data:[],error:null};
   if(statusMatchError)throw statusMatchError;
   const statusMatchMap=new Map((statusMatchRows||[]).map((m:Record<string,any>)=>[String(m.job_card_number)+"::"+String(m.normalized_fto_name),m]));
   const resolveStatusApplicant=(row:Record<string,any>)=>{
    const card=String(row.job_card_number),normalizedName=normalizeApplicantName(row.person_name);
    const saved=statusMatchMap.get(card+"::"+normalizedName) as Record<string,any>|undefined;
    if(saved){
     const mapped=(activeMisApplicants.get(card)||[]).filter(a=>String(a.applicant_unique_id||"")===String(saved.applicant_unique_id));
     if(mapped.length===1)return mapped[0];
    }
    return matchActiveMisApplicant(activeMisApplicants,card,String(row.person_name));
   };
   const unmatchedApplicantCards=[...new Set(normalized.filter(row=>!resolveStatusApplicant(row)).map(row=>String(row.job_card_number)))];
   if(unmatchedApplicantCards.length)return reply({error:"Some FTO applicant names could not be matched uniquely to active MIS. Use the FTO synchronization review to confirm these names before applying this status action.",unmatched_applicant_job_cards:unmatchedApplicantCards},409);
   let importId=prior?.id;
   if(!importId){const {data:created,error:createError}=await admin.from("vbgramg_charge_imports").insert({source_filename:sourceFilename,source_sha256:sourceSha,charge_period:period,row_count:normalized.length,total_amount:totalAmount,status:"staging",imported_by:authData.user.id,notes:("FTO status action: "+mode).slice(0,500)}).select("id").single();if(createError)throw createError;importId=created.id;}
   let inserted=0,updated=0,skipped=0;
   for(const row of normalized){
    const applicantMatch=resolveStatusApplicant(row);
    const applicantFields=applicantMatch?{applicant_name:applicantMatch.applicant_name,applicant_number:applicantMatch.applicant_number,applicant_unique_id:applicantMatch.applicant_unique_id}:{};
    const matches=byCard.get(String(row.job_card_number))||[],ftoMatches=matches.filter(ftoExisting);
    if(ftoMatches.length){
     const keeper=ftoMatches[0];
     const {error:updateError}=await admin.from("vbgramg_charge_ledger").update({person_name:row.person_name,amount:row.amount,is_deferred:mode==="blank",entry_date:mode==="blank"?null:(row.processed_date||null),note:"FTO import",reference_numbers:row.reference_numbers,period_id:periodId,...applicantFields}).eq("id",keeper.id);
     if(updateError)throw updateError;updated++;
     for(const extra of ftoMatches.slice(1)){if(extra.is_deferred===true){const {error:extraDeleteError}=await admin.from("vbgramg_charge_ledger").delete().eq("id",extra.id);if(extraDeleteError)throw extraDeleteError;}}
     continue;
    }
    const {error:insertError}=await admin.from("vbgramg_charge_ledger").insert({job_card_number:row.job_card_number,person_name:row.person_name,...applicantFields,entry_type:"charge",amount:row.amount,charge_period:period,entry_date:mode==="blank"?null:(row.processed_date||null),note:"FTO import",reference_numbers:row.reference_numbers,is_deferred:mode==="blank",created_by:authData.user.id,import_id:importId,period_id:periodId});
    if(insertError)throw insertError;inserted++;
   }
   const {error:completeError}=await admin.from("vbgramg_charge_imports").update({status:"complete",completed_at:new Date().toISOString(),row_count:normalized.length,total_amount:totalAmount}).eq("id",importId);if(completeError)throw completeError;
   return reply({approved:true,inserted,updated,deleted:0,skipped,total_amount:totalAmount,import_id:importId});
  }


  if(action==="save-contribution-extra"){
   if(approved.role!=="admin")return reply({error:"Only an approved administrator can save extra contribution charges."},403);
   const jobCard=String(body.job_card_number||"").trim(),period=String(body.charge_period||"").trim(),amount=Number(body.amount),reason=String(body.reason||"").trim().slice(0,500);
   const periodMatch=period.match(/^(\d{4})-(\d{2})-01$/);
   if(!jobCard)return reply({error:"Choose a job card."},400);
   if(!periodMatch||Number(periodMatch[2])<1||Number(periodMatch[2])>12)return reply({error:"Choose a valid contribution month."},400);
   if(!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Enter an extra amount greater than zero."},400);
   if(!reason)return reply({error:"Enter a reason for the extra amount."},400);
   const {data:known,error:knownError}=await admin.from("vbgramg_charge_ledger").select("person_name").eq("job_card_number",jobCard).limit(1).maybeSingle();
   if(knownError)throw knownError;
   const {data:citizen,error:citizenError}=await admin.from("vbgramg_contribution_citizens").select("job_card_number,person_name").eq("job_card_number",jobCard).maybeSingle();
   if(citizenError)throw citizenError;
   if(!known&&!citizen)return reply({error:"This job card is not present in the contribution records."},404);
   const personName=String(known?.person_name||citizen?.person_name||"").trim()||jobCard;
   const note=("FTO EXTRA: "+reason).slice(0,200);
   const {data:oldExtra,error:oldExtraError}=await admin.from("vbgramg_contribution_extras").select("id,ledger_entry_id,created_by").eq("job_card_number",jobCard).eq("charge_period",period).maybeSingle();
   if(oldExtraError)throw oldExtraError;
   let ledgerEntry:any=null;
   if(oldExtra?.ledger_entry_id){
    const {data:updated,error:updateError}=await admin.from("vbgramg_charge_ledger").update({person_name:personName,amount,entry_date:new Date().toISOString().slice(0,10),note,charge_period:period,is_deferred:false}).eq("id",oldExtra.ledger_entry_id).select("id,job_card_number,person_name,entry_type,amount,charge_period,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id").maybeSingle();
    if(updateError)throw updateError;
    ledgerEntry=updated;
   }
   if(!ledgerEntry){
    const {data:created,error:createError}=await admin.from("vbgramg_charge_ledger").insert({job_card_number:jobCard,person_name:personName,entry_type:"charge",amount,charge_period:period,entry_date:new Date().toISOString().slice(0,10),note,is_deferred:false,created_by:authData.user.id}).select("id,job_card_number,person_name,entry_type,amount,charge_period,entry_date,note,created_at,is_deferred,source_created_at_ms,legacy_entry_id").single();
    if(createError)throw createError;
    ledgerEntry=created;
   }
   const {data:extra,error:extraError}=await admin.from("vbgramg_contribution_extras").upsert({job_card_number:jobCard,person_name:personName,charge_period:period,amount,reason,ledger_entry_id:ledgerEntry.id,created_by:oldExtra?.created_by||authData.user.id,updated_by:authData.user.id,updated_at:new Date().toISOString()},{onConflict:"job_card_number,charge_period"}).select("id,job_card_number,person_name,charge_period,amount,reason,ledger_entry_id,created_at,updated_at").single();
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
   const isLegacyReturn=type==="charge"&&String(old.note||"").trim().toLowerCase()==="return";
   if(!["charge","payment","return","forgive","sanitationFee"].includes(type))return reply({error:"This transaction type cannot be edited here."},400);
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
    else if(t==="return"||(t==="charge"&&String(e.note||"").trim().toLowerCase()==="return"))returns+=n;
    else if(t==="forgive")waived+=n;
    else if((t==="charge"||t==="sanitationFee")&&!e.is_deferred)charges+=n;
   }
   const balance=charges-Math.min(waived,charges)-paid+returns;
   let amount=requestedAmount,type="",finalNote=note;
   if(action==="pay-in-full"){amount=Math.max(0,Number(balance.toFixed(2)));type="payment";finalNote="Cash";}
   else if(action==="add-waiver"){type="forgive";if(!Number.isFinite(amount)||amount<=0||amount>Math.max(0,balance)+0.001)return reply({error:"Waiver must be positive and cannot exceed the current outstanding balance."},400);}
   else {type="return";if(!Number.isFinite(amount)||amount<=0||amount>Math.max(0,paid-returns)+0.001)return reply({error:"Return amount must be positive and cannot exceed payments less previous returns."},400);}
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
    const jobCard=String(raw.job_card_number||"").trim(),personName=String(raw.person_name||"").trim(),sourceId=String(raw.legacy_entry_id||"").trim(),type=String(raw.entry_type||""),amount=Number(raw.amount),note=String(raw.note||"").slice(0,200),ms=Number(raw.source_created_at_ms||0);
    if(!jobCard||!personName||!sourceId||!["charge","payment","return","forgive","sanitationFee"].includes(type)||!Number.isFinite(amount)||amount<=0||amount>10000000)return reply({error:"Backup contains an invalid ledger row. Nothing from this batch was imported."},400);
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