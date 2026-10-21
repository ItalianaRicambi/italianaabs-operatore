import {test} from 'node:test';
import assert from 'node:assert/strict';
import {elencoConversazioniK} from './conversazioniKeplero.ts';
const id='11111111-1111-4111-8111-111111111111';
test('non si ferma sulle chat aperte vecchie: legge anche la pagina delle chiuse recenti',async()=>{
 let pagine=0;
 const x=await elencoConversazioniK(id,'chiave-test',async(_url,opts)=>{
  assert.equal(opts?.redirect,'error');pagine++;
  const data=pagine===1?Array.from({length:50},(_,n)=>({session_id:`00000000-0000-4000-8000-${String(n).padStart(12,'0')}`,last_message_timestamp:'2026-09-01 10:00:00+00'})):[{session_id:id,last_message_timestamp:'2026-10-21 10:00:00+00'}];
  return Response.json({data,pagination:{total:51}});
 });
 assert.equal(pagine,2);assert.equal(x.at(-1)?.sessione,id);
});
test('elenco parziale o schema errato non dichiara copertura completa',async()=>{
 for(const body of [{data:[{session_id:'altra',last_message_timestamp:'2026-10-21'}]},{data:[{session_id:id,last_message_timestamp:'2026-10-21 10:00:00'}]},{errore:'non autorizzato'}]){
  await assert.rejects(elencoConversazioniK(id,'chiave',async()=>Response.json(body)));
 }
});
