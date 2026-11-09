import {test} from 'node:test';
import assert from 'node:assert/strict';
import {runReminder,reconcileStored,type Review,type Dependencies,type Store} from './runner.ts';
import type {Attempt} from './transport.ts';
const now=Date.parse('2026-11-10T10:00:00Z'),session='00000000-0000-4000-a000-000000000001';
function review():Review{return {session,to:'+390000000001',practiceVersion:'v1',messageIds:['1'],expectedText:'Pratica ABS-999999: foto leggibili del componente',context:{
 enabledAfter:'2026-11-09T00:00:00Z',calendar:{confirmedThrough:'2026-12-31',closures:[]},
 request:{practiceId:'test',phase:'preventivo',messageId:'1',sentAt:'2026-11-09T10:00:00Z',sourceFingerprint:'a'.repeat(64),deliveryConfirmed:true,fields:['foto']},
 ledger:{state:'none',sentAt:null,messageId:null},
 snapshot:{practiceId:'test',practiceNumber:'ABS-999999',channel:'whatsapp',phase:'preventivo',commercialState:'raccolta_dati',completeness:'dati_mancanti',quoteIssued:false,acceptedOrder:false,invoiceOrProformaIssued:false,closedOrDeclined:false,operatorBlocked:false,responsePendingReview:false,fiscalRegistryChecked:false,fiscalRegistryAmbiguous:false,missing:['foto'],readStartedAt:new Date(now-1000).toISOString(),readFinishedAt:new Date(now).toISOString(),allOriginalsRead:true,allAttachmentsReviewed:true,originalRequestPresent:true,originalRequestUnchanged:true,customerReplyAtOrAfterRequest:false,unknownDirectionAfterRequest:false,sourceFingerprint:'b'.repeat(64)},
 }};}
function setup(){
 let state='none',calls=0,activity=false;let attempt:Attempt|undefined;
 const store:Store={
  async claim(){if(state!=='none')return null;state='claimed';return 'claim';},
  async begin(_claim,_review,a){if(state!=='claimed'||attempt)return false;attempt=a;return true;},
  async finish(_claim,next){if(state==='sent'||state==='cancelled')return false;if(state==='ambiguous'&&next!=='sent')return false;state=next;return true;},
  async escalate(){if(activity)return false;activity=true;return true;},
 };
 const d:Dependencies={store,review:async()=>review(),now:()=>now,
  send:async()=>{calls++;return {kind:'accepted',session};},
  messages:async()=>[{id:'2',session,timestamp:new Date(now).toISOString(),type:'text',content:review().expectedText,sender:'assistant',sender_type:'operator',metadata:{wa_message_id:'wamid.synthetic',templateOrigin:{type:'manual_operator'}},whatsapp_message:{status:'sent'}}],
 };
 return {d,state:()=>state,calls:()=>calls,attempt:()=>attempt!};
}
test('synthetic end-to-end: claim, second review, durable attempt, POST, original ID',async()=>{
 const s=setup();assert.equal((await runReminder(s.d)).kind,'sent');assert.equal(s.calls(),1);assert.equal(s.state(),'sent');
 assert.equal((await runReminder(s.d)).reason,'claim_unavailable');assert.equal(s.calls(),1);
});
test('20 concurrent workers with atomic store contract send only once',async()=>{
 const s=setup();const results=await Promise.all(Array.from({length:20},()=>runReminder(s.d)));
 assert.equal(results.filter(r=>r.kind==='sent').length,1);assert.equal(s.calls(),1);
});
test('reply, invoice, quote, block, completed data or stale evidence between claim and POST cancel',async()=>{
 const changes:Array<(r:Review)=>void>=[r=>{r.context.snapshot.customerReplyAtOrAfterRequest=true;},r=>{r.context.snapshot.invoiceOrProformaIssued=true;},r=>{r.context.snapshot.quoteIssued=true;},r=>{r.context.snapshot.operatorBlocked=true;},r=>{r.context.snapshot.missing=[];},r=>{r.context.snapshot.readStartedAt='2026-11-09T10:00:00Z';},r=>{r.to='+390000000002';}];
 for(const change of changes){const s=setup();let reads=0;s.d.review=async()=>{const r=review();if(reads++)change(r);return r;};assert.equal((await runReminder(s.d)).kind,'cancelled');assert.equal(s.calls(),0);}
});
test('database refusal or lost acknowledgement before POST never sends',async()=>{
 for(const lost of [false,true]){const s=setup();s.d.store.begin=async()=>{if(lost)throw new Error('lost DB ack');return false;};await runReminder(s.d);assert.equal(s.calls(),0);}
});
test('200 without retrievable original is ambiguous; later recovery reads only and confirms',async()=>{
 const s=setup();const messages=s.d.messages;s.d.messages=async()=>[];
 assert.equal((await runReminder(s.d)).kind,'ambiguous');assert.equal(s.calls(),1);
 await runReminder(s.d);assert.equal(s.calls(),1);
 s.d.messages=messages;assert.equal((await reconcileStored({claim:'claim',attempt:s.attempt()},s.d)).kind,'sent');assert.equal(s.calls(),1);
});
test('lost HTTP ack and lost confirmation write do not authorize retry',async()=>{
 const s=setup();s.d.send=async()=>({kind:'ambiguous',code:'timeout'});s.d.messages=async()=>[];
 assert.equal((await runReminder(s.d)).kind,'ambiguous');
 const t=setup();const finish=t.d.store.finish;t.d.store.finish=async(...args)=>{if(args[1]==='sent')throw new Error('lost DB response');return finish(...args);};
 assert.equal((await runReminder(t.d)).kind,'ambiguous');assert.equal(t.calls(),1);await runReminder(t.d);assert.equal(t.calls(),1);
});
test('definitive rejection consumes slot and never retries',async()=>{
 const s=setup();let calls=0;s.d.send=async()=>{calls++;return {kind:'rejected',code:'provider_rejected'};};
 assert.equal((await runReminder(s.d)).kind,'cancelled');await runReminder(s.d);assert.equal(calls,1);
});
test('48h escalation creates one activity and no further messages; replies stop escalation',async()=>{
 const s=setup();s.d.now=()=>now+48*3600000;s.d.review=async()=>{const r=review();r.context.ledger={state:'sent',sentAt:new Date(now).toISOString(),messageId:'wamid.synthetic'};r.context.snapshot.readStartedAt=r.context.snapshot.readFinishedAt=new Date(s.d.now()).toISOString();return r;};
 assert.equal((await runReminder(s.d)).kind,'escalated');assert.equal((await runReminder(s.d)).kind,'stop');assert.equal(s.calls(),0);
 const t=setup();t.d.now=s.d.now;t.d.review=async()=>{const r=await s.d.review();r.context.snapshot.customerReplyAtOrAfterRequest=true;return r;};assert.equal((await runReminder(t.d)).kind,'stop');assert.equal(t.calls(),0);
});
test('slow database acknowledgement cannot send with stale review',async()=>{
 const s=setup();const begin=s.d.store.begin;s.d.store.begin=async(...args)=>{const ok=await begin(...args);s.d.now=()=>now+16000;return ok;};
 assert.equal((await runReminder(s.d)).reason,'expired_before_dispatch');assert.equal(s.calls(),0);
});
