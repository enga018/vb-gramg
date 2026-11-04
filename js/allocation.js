/* Shared Contribution allocation calculations.
 * Pure FIFO/explicit-allocation calculations only.
 * Rendering and all financial writes remain in contribution.html/server functions.
 */
(function () {
  "use strict";

  function calculateFifoGroups(options) {
    const {
      ledger = [],
      waived = 0,
      paid = 0,
      returns = 0,
      paymentAllocations = [],
      periods = []
    } = options || {};
 const charges=(c.ledger||[]).filter(e=>{
  const t=e.entry_type;
  return !e.is_voided&&!e.is_deferred&&(t==='charge'||t==='other_charge'||t==='sanitationFee')&&!(t==='charge'&&String(e.note||'').trim()==='Return');
 }).map(e=>({...e,remaining:Math.max(0,Number(e.amount)||0),allocated:0,waivedAmount:0}));
 const sortKey=e=>String(e.charge_period||e.entry_date||e.created_at||'').slice(0,10);
 charges.sort((a,b)=>sortKey(a).localeCompare(sortKey(b))||String(a.entry_date||'').localeCompare(String(b.entry_date||''))||String(a.created_at||'').localeCompare(String(b.created_at||'')));
 let waiverCredit=Math.min(Math.max(0,Number(c.waived)||0),charges.reduce((sum,e)=>sum+e.remaining,0));
 for(const charge of charges){if(waiverCredit<=0)break;const used=Math.min(charge.remaining,waiverCredit);charge.remaining-=used;charge.waivedAmount=used;waiverCredit-=used;}
 const cardPayments=(c.ledger||[]).filter(e=>e.entry_type==='payment');
 const cardPaymentIds=new Set(cardPayments.map(e=>String(e.id)));
 const cardAllocations=paymentAllocations.filter(a=>cardPaymentIds.has(String(a.transaction_id)));
 const allocatedByPeriod=new Map();
 for(const a of cardAllocations){const amount=Math.max(0,Number(a.amount)||0);const key=String(a.period_id||'');allocatedByPeriod.set(key,(allocatedByPeriod.get(key)||0)+amount);}
 // Count only amounts that can actually be applied to a matching period charge.
 // Any excess allocation remains unallocated credit and can still settle older outstanding periods.
 let explicitlyApplied=0;
 for(const charge of charges){
  const key=String(charge.period_id||'');if(!key)continue;
  const available=allocatedByPeriod.get(key)||0;if(available<=0)continue;
  const used=Math.min(charge.remaining,available);charge.remaining-=used;charge.allocated+=used;explicitlyApplied+=used;allocatedByPeriod.set(key,available-used);
 }
 // Payments without a usable explicit allocation retain the existing FIFO treatment.
 const netPaymentCredit=Math.max(0,(Number(c.paid)||0)-(Number(c.returns)||0)-explicitlyApplied);
 let paymentCredit=netPaymentCredit;
 for(const charge of charges){if(paymentCredit<=0)break;const used=Math.min(charge.remaining,paymentCredit);charge.remaining-=used;charge.allocated+=used;paymentCredit-=used;}
 const groups=new Map();
 charges.forEach((e,index)=>{
  const isOther=e.entry_type==='other_charge'||e.entry_type==='sanitationFee';
  const isExtra=e.entry_type==='charge'&&/^FTO EXTRA:/i.test(String(e.note||''));
  const periodValue=String(e.charge_period||e.entry_date||e.created_at||'').slice(0,10);
  const key=isOther?'special:'+String(e.id||index):isExtra?'extra:'+String(e.period_id||periodValue)+':'+String(e.id||index):'period:'+(e.period_id?'id:'+String(e.period_id):periodValue);
  const periodRow=e.period_id&&Array.isArray(periods)?periods.find(p=>String(p.id)===String(e.period_id)):null;
  const label=isOther?'Other charge':isExtra?'Extra charge':String(periodRow?.period_name||'').trim()||formatPeriod(e.charge_period||e.entry_date||e.created_at);
  if(!groups.has(key))groups.set(key,{key,label,entries:[],total:0,paid:0,due:0,waived:0,firstSort:sortKey(e)});
  const g=groups.get(key);g.entries.push(e);g.total+=Math.max(0,Number(e.amount)||0);g.paid+=e.allocated;g.due+=e.remaining;g.waived+=e.waivedAmount;
 });
 const groupList=[...groups.values()].sort((a,b)=>a.firstSort.localeCompare(b.firstSort)||a.label.localeCompare(b.label));

    return { groups: groupList };
  }

  window.VBGRAMGAllocation = Object.freeze({
    calculateFifoGroups
  });
})();
