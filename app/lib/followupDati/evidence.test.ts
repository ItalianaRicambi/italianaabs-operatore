import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readLiveEvidence,findTargetedRequest,reviewCustomerReplies} from './evidence.ts';
const calendar={confirmedThrough:'2026-12-31',closures:[]};
const session='00000000-0000-4000-a000-000000000001',now=Date.parse('2026-11-10T10:00:00Z');
const text={id:'1',session,timestamp:'2026-11-09T10:00:00Z',sender:'assistant',type:'text',content:'Ci invia le foto?',whatsapp_message:{status:'delivered'}};
const draft={practiceId:'test',phase:'preventivo' as const,exactText:text.content,fields:['foto' as const],cutover:'2026-11-09T00:00:00Z'};
test('reads every attachment, including more than eight, and hashes current bytes',async()=>{
 const messages=[text,...Array.from({length:10},(_,i)=>({...text,id:String(i+2),type:'image',content:`attachment:https://v2.api.keplero.ai/v2/session-attachments/${i}.jpg`}))];let calls=0;
 const e=await readLiveEvidence(session,async()=>messages,async()=>{calls++;return new Response('synthetic image');},()=>now);
 assert.equal(calls,10);assert.equal(e.attachments.length,10);assert.equal(e.fingerprint.length,64);
});
test('changed conversation, failed media or unsupported origin blocks entire evidence',async()=>{
 let reads=0;await assert.rejects(()=>readLiveEvidence(session,async()=>++reads===1?[text]:[text,{...text,id:'2',sender:'user'}],fetch,()=>now));
 for(const content of ['attachment:https://example.com/x','attachment:https://v2.api.keplero.ai/v2/session-attachments/x','unavailable'])
  await assert.rejects(()=>readLiveEvidence(session,async()=>[{...text,type:'image',content}],async()=>new Response('',{status:404}),()=>now));
});
test('exact targeted original: real date, proof, new partial request resets timer; generic/manual/historical do not',async()=>{
 const e=await readLiveEvidence(session,async()=>[text],fetch,()=>now);assert.equal(findTargetedRequest(draft,e,calendar)?.sentAt,'2026-11-09T10:00:00.000Z');
 assert.equal(findTargetedRequest({...draft,exactText:'Grazie'},e,calendar),null);assert.equal(findTargetedRequest({...draft,cutover:'2026-11-10T00:00:00Z'},e,calendar),null);
 const pending=await readLiveEvidence(session,async()=>[{...text,whatsapp_message:{status:'pending'}}],fetch,()=>now);assert.equal(findTargetedRequest(draft,pending,calendar),null);
 const incoming={...text,id:'2',sender:'user',timestamp:'2026-11-09T11:00:00Z',content:'Ecco la targa'};
 const partial=await readLiveEvidence(session,async()=>[text,incoming,{...text,id:'3',timestamp:'2026-11-09T12:00:00Z'}],fetch,()=>now);
 assert.equal(findTargetedRequest(draft,partial,calendar)?.sentAt,'2026-11-09T12:00:00.000Z');
 const answered=await readLiveEvidence(session,async()=>[text,incoming],fetch,()=>now);assert.equal(findTargetedRequest(draft,answered,calendar),null);
});

test('customer timing is tied to the original message and only lifts a verified reply hold',async()=>{
 const sentAt='2026-11-09T11:00:00Z';
 const incoming={...text,id:'2',sender:'user',timestamp:sentAt};
 const check=async(content:string,type='text')=>{
  const e=await readLiveEvidence(session,async()=>[text,{...incoming,type,content}],
   async()=>new Response('file'),()=>now);
  return {request:findTargetedRequest(draft,e,calendar),review:reviewCustomerReplies(text.timestamp,e,calendar),e};
 };
 for (const [message,expected] of [
  ['Vi faccio sapere appena riesco','2026-11-13T08:00:00.000Z'],
  ['Appena riesco ve li mando','2026-11-13T08:00:00.000Z'],
  ['Vi farò sapere appena posso','2026-11-13T08:00:00.000Z'],
  ['Vi mando i dati fiscali quando riesco','2026-11-13T08:00:00.000Z'],
  ['Settimana prossima vado dal meccanico e vi comunico i codici guasto','2026-11-16T11:00:00.000Z'],
  ['Ve li mando tra una settimana','2026-11-16T11:00:00.000Z'],
  ['Vi mando i dati fiscali entro venerdì','2026-11-13T23:00:00.000Z'],
  ['Vi invierò tutto il 20/11','2026-11-20T23:00:00.000Z'],
  ['Vi invio i dati entro il 20 novembre','2026-11-20T23:00:00.000Z'],
  ['La prossima settimana vado dal meccanico e vi faccio sapere','2026-11-16T11:00:00.000Z'],
  ['Vi mando tutto entro la fine della prossima settimana','2026-11-22T23:00:00.000Z'],
  ['Domani passo dal commercialista e vi mando i dati di fatturazione','2026-11-10T23:00:00.000Z'],
 ]) {
  const {request,review,e}=await check(message);
  assert.equal(request?.messageId,'1',message);
  assert.deepEqual(review.customerDeferral,{notBefore:expected,
   messages:[{id:'2',fingerprint:e.originals[1].impronta}],conversationFingerprint:e.fingerprint},message);
 }
 for (const message of ['Non ricontattatemi, vi faccio sapere appena riesco','Non vi mando i dati entro venerdì',
  'Vi invio i dati il 31/11','Vi invio i dati il 05/11','Vi mando i dati entro venerdì?','Ecco le foto']) {
  const {request,review}=await check(message);
  assert.equal(request,null,message);
  assert.equal(review.responsePendingReview,true,message);
 }
 const media=await check('attachment:https://v2.api.keplero.ai/v2/session-attachments/audio.ogg','audio');
 assert.equal(media.request,null);
 assert.equal(media.review.responsePendingReview,true);
});

test('a later unclassified reply holds an earlier deferral, and a longer explicit extension takes precedence',async()=>{
 const incoming={...text,id:'2',sender:'user',timestamp:'2026-11-09T11:00:00Z',content:'Vi mando le foto tra una settimana'};
 const update={...incoming,id:'3',timestamp:'2026-11-09T13:00:00Z'};
 const read=(content:string)=>readLiveEvidence(session,async()=>[text,incoming,{...update,content}],fetch,()=>now);
 const extended=await read('Vi mando le foto tra due settimane');
 assert.equal(reviewCustomerReplies(text.timestamp,extended,calendar).customerDeferral?.notBefore,'2026-11-23T13:00:00.000Z');
 const answered=await read('In allegato le foto');
 assert.equal(reviewCustomerReplies(text.timestamp,answered,calendar).responsePendingReview,true);
});

test('a date supplied later supersedes the four-day fallback; an uncovered calendar holds the fallback',async()=>{
 const incoming={...text,id:'2',sender:'user',timestamp:'2026-11-09T11:00:00Z',content:'Vi faccio sapere appena riesco'};
 const dated={...incoming,id:'3',timestamp:'2026-11-09T13:00:00Z',content:'Vi invio le foto domani'};
 const restricted={...calendar,confirmedThrough:'2026-11-12'};
 const onlyUndated=await readLiveEvidence(session,async()=>[text,incoming],fetch,()=>now);
 assert.equal(reviewCustomerReplies(text.timestamp,onlyUndated,restricted).responsePendingReview,true);
 const withDate=await readLiveEvidence(session,async()=>[text,incoming,dated],fetch,()=>now);
 assert.equal(reviewCustomerReplies(text.timestamp,withDate,restricted).customerDeferral?.notBefore,'2026-11-10T23:00:00.000Z');
});
