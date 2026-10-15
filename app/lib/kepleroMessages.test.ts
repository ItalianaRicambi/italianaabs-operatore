import test from 'node:test';
import assert from 'node:assert/strict';
import { recuperaMessaggiKeplero, ErroreMessaggiKeplero } from './kepleroMessages.ts';
const session = 'b3be5f5b-ece5-4c5e-90be-e39d856fe12f';
const key = 'chiave-fittizia-test';
const risposta = (page: number, total: number, data: unknown[]) => Response.json({data,pagination:{page,perPage:100,total}});
const errore = (codice: string) => (e: unknown) => e instanceof ErroreMessaggiKeplero && e.codice === codice && !e.message.includes(key);
test('host fisso, Bearer solo server, pagine complete dal più recente', async () => {
 const chiamate: string[] = [];
 const prima = Array.from({length:100}, (_,i)=>({id:101-i,type:'email',content:'Dati non attendibili'}));
 const messages = await recuperaMessaggiKeplero(session,key,async (input,init)=>{
  chiamate.push(String(input));
  assert.equal(init?.headers && (init.headers as Record<string,string>).Authorization,`Bearer ${key}`);
  assert.equal(init?.cache,'no-store'); assert.equal(init?.redirect,'error'); assert.ok(init?.signal);
  return chiamate.length===1 ? risposta(1,101,prima) : risposta(2,101,[{id:1,type:'file',content:'attachment:https://files.example.test/a.pdf'}]);
 });
 assert.deepEqual(chiamate,[1,2].map(page=>`https://v2.api.keplero.ai/v2/sessions/${session}/messages?page=${page}&perPage=100`));
 assert.equal(messages.length,101); assert.equal(messages[100].id,1);
});
test('identificativi e configurazione mancanti non causano richieste',async()=>{
 const mai: typeof fetch = async()=>{throw new Error('non deve essere chiamato');};
 await assert.rejects(recuperaMessaggiKeplero('../altro',key,mai),errore('conversazione_non_valida'));
 await assert.rejects(recuperaMessaggiKeplero(session,undefined,mai),errore('non_configurato'));
 await assert.rejects(recuperaMessaggiKeplero(session,'a\nb',mai),errore('non_configurato'));
});
test('errori remoti e di rete non espongono il body o la chiave',async()=>{
 for (const status of [401,403,429,500]) {
  await assert.rejects(recuperaMessaggiKeplero(session,key,async()=>new Response(key,{status})),errore(status<404?'non_autorizzato':'non_disponibile'));
 }
 await assert.rejects(recuperaMessaggiKeplero(session,key,async()=>{throw new Error(key);}),errore('non_disponibile'));
});
test('schema, pagine incomplete e conversazione mutata non restituiscono risultati parziali',async()=>{
 for (const value of [{data:[]},{data:['testo'],pagination:{page:1,perPage:100,total:1}},{data:[],pagination:{page:2,perPage:100,total:0}},{data:[],pagination:{page:1,perPage:100,total:1}}]) {
  await assert.rejects(recuperaMessaggiKeplero(session,key,async()=>Response.json(value)),errore('risposta_non_valida'));
 }
 let n=0;
 await assert.rejects(recuperaMessaggiKeplero(session,key,async()=>++n===1?risposta(1,101,Array.from({length:100},()=>({}))):risposta(2,102,[{},{}])),errore('risposta_non_valida'));
});
test('limiti su conteggio e byte; conversazione vuota valida',async()=>{
 await assert.rejects(recuperaMessaggiKeplero(session,key,async()=>risposta(1,5001,[])),errore('limite_superato'));
 await assert.rejects(recuperaMessaggiKeplero(session,key,async()=>new Response('x'.repeat(4*1024*1024+1))),errore('limite_superato'));
 assert.deepEqual(await recuperaMessaggiKeplero(session,key,async()=>risposta(1,0,[])),[]);
});

test('normalizza il prefisso Bearer e gli spazi esterni senza esporre il token',async()=>{
 await recuperaMessaggiKeplero(session,` \nBearer ${key}\n `,async(_input,init)=>{
  assert.equal((init?.headers as Record<string,string>).Authorization,`Bearer ${key}`);
  return risposta(1,0,[]);
 });
 for(const status of [401,403]) {
  await assert.rejects(recuperaMessaggiKeplero(session,key,async()=>new Response('',{status})),e=>e instanceof ErroreMessaggiKeplero && e.codice==='non_autorizzato' && e.statoHttp===status && !e.message.includes(key));
 }
});
