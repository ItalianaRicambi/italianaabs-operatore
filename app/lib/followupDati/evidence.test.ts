import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readLiveEvidence,findTargetedRequest} from './evidence.ts';
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
 const e=await readLiveEvidence(session,async()=>[text],fetch,()=>now);assert.equal(findTargetedRequest(draft,e)?.sentAt,'2026-11-09T10:00:00.000Z');
 assert.equal(findTargetedRequest({...draft,exactText:'Grazie'},e),null);assert.equal(findTargetedRequest({...draft,cutover:'2026-11-10T00:00:00Z'},e),null);
 const pending=await readLiveEvidence(session,async()=>[{...text,whatsapp_message:{status:'pending'}}],fetch,()=>now);assert.equal(findTargetedRequest(draft,pending),null);
 const incoming={...text,id:'2',sender:'user',timestamp:'2026-11-09T11:00:00Z',content:'Ecco la targa'};
 const partial=await readLiveEvidence(session,async()=>[text,incoming,{...text,id:'3',timestamp:'2026-11-09T12:00:00Z'}],fetch,()=>now);
 assert.equal(findTargetedRequest(draft,partial)?.sentAt,'2026-11-09T12:00:00.000Z');
 const answered=await readLiveEvidence(session,async()=>[text,incoming],fetch,()=>now);assert.equal(findTargetedRequest(draft,answered),null);
});
