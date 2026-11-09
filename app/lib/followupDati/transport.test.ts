import {test} from 'node:test';
import assert from 'node:assert/strict';
import {sendTemplate,reconcile,BOT,type Attempt} from './transport.ts';
const session='00000000-0000-4000-a000-000000000001';
const attempt:Attempt={phase:'preventivo',session,to:'+390000000001',variables:['ABS-999999','foto leggibili del componente'],startedAt:'2026-11-10T10:00:00.250Z',beforeIds:['10'],expectedText:'Pratica ABS-999999: foto leggibili del componente'};
const raw=(id=11,content=attempt.expectedText,status='sent')=>({session,id,content,type:'text',timestamp:'2026-11-10T10:00:01Z',sender:'assistant',sender_type:'operator',metadata:{wa_message_id:`wamid.synthetic.${id}`,templateOrigin:{type:'manual_operator'}},whatsapp_message:{status}});
const now=Date.parse('2026-11-10T10:00:10Z');
test('documented direct POST: only two variables, exact bot, no redirect or retry',async()=>{
 let calls=0;
 const result=await sendTemplate({...attempt,variables:['ABS-999999','foto\n  leggibili\tdel componente']},'synthetic',async(url,init)=>{
  calls++;assert.equal(url,`https://v2.api.keplero.ai/conversations/${BOT}/send-template`);
  assert.equal(init?.method,'POST');assert.equal(init?.redirect,'error');assert.equal(init?.cache,'no-store');
  assert.deepEqual(JSON.parse(String(init?.body)),{channel:'whatsapp',name:'italianaabs_dati_preventivo_24h',language:'it',to:attempt.to,variables:attempt.variables});
  return Response.json({sessionId:session});
 });
 assert.deepEqual(result,{kind:'accepted',session});assert.equal(calls,1);
});
test('invalid recipient and missing secret never reach the network',async()=>{
 let calls=0;const fetcher:typeof fetch=async()=>{calls++;return Response.json({});};
 await assert.rejects(()=>sendTemplate({...attempt,to:'3331234567'},'synthetic',fetcher));
 await assert.rejects(()=>sendTemplate(attempt,undefined,fetcher));assert.equal(calls,0);
});
test('documented 400 is rejection; 5xx, malformed, mismatch, redirect and timeout are ambiguous with one attempt',async()=>{
 for(const [status,body,kind] of [[400,{message:'Failed to send template'},'rejected'],[400,{message:'Invalid phone number'},'rejected'],[500,{message:'Failed to send template'},'ambiguous'],[200,{sessionId:'other'},'ambiguous'],[400,{},'ambiguous']] as const){
  let count=0;const result=await sendTemplate(attempt,'synthetic',async()=>{count++;return Response.json(body,{status});});assert.equal(result.kind,kind);assert.equal(count,1);
 }
 let count=0;assert.equal((await sendTemplate(attempt,'synthetic',async()=>{count++;throw new Error('synthetic timeout');})).kind,'ambiguous');assert.equal(count,1);
 assert.equal((await sendTemplate(attempt,'synthetic',async()=>new Response('{broken'))).kind,'ambiguous');
 assert.equal((await sendTemplate(attempt,'synthetic',async()=>new Response('x'.repeat(17000)))).kind,'ambiguous');
});
test('reconciliation requires exact text, unique fresh ID, documented sender, provider ID and confirmation',()=>{
 assert.equal(reconcile(attempt,[raw()],now)?.providerMessageId,'wamid.synthetic.11');
 for(const messages of [[raw(10)],[raw(11,'Pratica ABS-999999: altro messaggio')],[raw(),raw(12)],[raw(11,attempt.expectedText,'failed')],
  [{...raw(),sender:'user'}],[{...raw(),metadata:{}}],[{...raw(),timestamp:'2026-11-10T10:02:00Z'}]])assert.equal(reconcile(attempt,messages,now),null);
});
test('second-resolution timestamps are matched using before-IDs, never guessed dates',()=>{
 const receipt=reconcile(attempt,[{...raw(),timestamp:'2026-11-10T10:00:00Z'}],now);assert.equal(receipt?.sentAt,'2026-11-10T10:00:00.000Z');
 assert.equal(reconcile(attempt,[{...raw(),timestamp:'2026-11-10T09:59:59Z'}],now),null);
});
