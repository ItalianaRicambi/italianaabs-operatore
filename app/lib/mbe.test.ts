import test from 'node:test';
import assert from 'node:assert/strict';
import {creaClientMbe,contenitoreMbe,paginaMbe,esitiMbe,ErroreMbe} from './mbe.ts';
const chiave='password-fittizia-test',id='correlazione-test';
const codice=(i:number)=>`IT0001-0L-${String(i).padStart(10,'0')}`;
const soap=(op:string,c:string)=>`<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/"><SOAP-ENV:Body><ns3:${op}Response xmlns:ns3="http://www.onlinembe.eu/ws/"><RequestContainer><Status>OK</Status>${c}</RequestContainer></ns3:${op}Response></SOAP-ENV:Body></SOAP-ENV:Envelope>`;
const spedizione=(i:number)=>`<ShipmentFullInfo><ReceiverInfo><Name>Officina &amp; Figli</Name><City>Galliate</City><Country>IT</Country><Emails>non-memorizzare@example.test</Emails></ReceiverInfo><ShipmentInfo><Date>2026-10-15</Date><Referring>ABS-000123 — XX000XX</Referring><ShipmentToBeClosed>true</ShipmentToBeClosed></ShipmentInfo><TrackingInfo><MasterTrackingMBE>${codice(i)}</MasterTrackingMBE><CourierMasterTrk>0012345</CourierMasterTrk><PresignedLinks><string>https://example.test/etichetta</string></PresignedLinks></TrackingInfo></ShipmentFullInfo>`;
const pagina=(page:number,total:number,righe:string,ref=id)=>soap('ShipmentsListV3Request',`<InternalReferenceID>${ref}</InternalReferenceID><Page>${page}</Page><TotalPages>${total}</TotalPages><ShipmentsFullInfo>${righe}</ShipmentsFullInfo>`);
test('campi reali WSDL, prefissi e zeri conservati; etichette ed email escluse',()=>{
 const r=paginaMbe(contenitoreMbe(pagina(1,1,spedizione(1)),'ShipmentsListV3Request',id),1).spedizioni[0];
 assert.equal(r.tracking_mbe,codice(1));assert.equal(r.tracking_corriere,'0012345');assert.equal(r.riferimento,'ABS-000123 — XX000XX');assert.equal(r.bozza,true);assert.equal(r.destinatario.nome,'Officina & Figli');
 assert.ok(!JSON.stringify(r).includes('etichetta'));assert.ok(!JSON.stringify(r).includes('non-memorizzare'));
});
test('paginazione completa, autenticazione HTTP soltanto, host e operazioni fissi',async()=>{
 const chiamate:string[]=[];
 const c=creaClientMbe('utente-fittizio',chiave,async(url,init)=>{
  assert.equal(url,'https://api.mbeonline.it/ws');assert.equal(init?.redirect,'error');assert.equal(init?.cache,'no-store');assert.ok(init?.signal);
  assert.equal((init!.headers as Record<string,string>).Authorization,`Basic ${Buffer.from(`utente-fittizio:${chiave}`).toString('base64')}`);
  const body=String(init?.body);chiamate.push(body);assert.ok(!body.includes(chiave));assert.ok(!body.includes('utente-fittizio'));assert.ok(body.includes('<WithCourierWaybill>false</WithCourierWaybill>'));
  const ref=body.match(/<InternalReferenceID>([^<]+)</)![1],page=Number(body.match(/<Page>(\d+)</)![1]);
  return new Response(pagina(page,2,page===1?Array.from({length:25},(_,i)=>spedizione(i)).join(''):spedizione(25),ref));
 });
 const righe=await c.spedizioni('2026-09-16','2026-10-16');assert.equal(righe.length,26);assert.equal(chiamate.length,2);
});
test('seconda pagina fallita o account mutato: nessun risultato parziale',async()=>{
 for(const mutato of [true,false]){
  let n=0;const c=creaClientMbe('utente',chiave,async(_url,init)=>{
   const ref=String(init?.body).match(/<InternalReferenceID>([^<]+)</)![1];n++;
   return n===1?new Response(pagina(1,2,spedizione(1),ref)):mutato?new Response(pagina(2,3,spedizione(2),ref)):new Response(chiave,{status:429});
  });await assert.rejects(c.spedizioni('2026-09-16','2026-10-16'),ErroreMbe);
 }
});
test('tracking singolo e batch, identità esatte, solo stati documentati',()=>{
 const single=esitiMbe({TrackingStatus:'WAITING_DELIVERY'},[codice(1)]);assert.equal(single[0].stato,'WAITING_DELIVERY');
 const batch=esitiMbe({TrackingResult:[{TrackingMBE:codice(2),TrackingStatus:'PARTIALLY_DELIVERED'},{TrackingMBE:codice(1),TrackingStatus:'DELIVERED',DeliveryDate:'2026-10-15'}]},[codice(1),codice(2)]);
 assert.equal(batch[1].data_consegna,'2026-10-15');
 for(const r of [{TrackingStatus:'DELIVERED'},{TrackingResult:[{TrackingMBE:codice(3),TrackingStatus:'DELIVERED'}]},{TrackingResult:[{TrackingMBE:codice(1),TrackingStatus:'IN_TRANSIT'}]}])assert.throws(()=>esitiMbe(r,[codice(1),codice(2)]),ErroreMbe);
 assert.throws(()=>esitiMbe({TrackingResult:[{TrackingMBE:codice(1),TrackingStatus:'DELIVERED'},{TrackingMBE:codice(1),TrackingStatus:'DELIVERED'}]},[codice(1),codice(2)]),ErroreMbe);
});
test('tracking in gruppi di 100 e codice corriere non confuso col codice MBE',async()=>{
 let n=0;const ids=Array.from({length:101},(_,i)=>codice(i));
 const c=creaClientMbe('utente',chiave,async(_url,init)=>{const body=String(init?.body);const richiesti=[...body.matchAll(/<TrackingMBE>([^<]+)<\/TrackingMBE>/g)].map(m=>m[1]);assert.ok(richiesti.length<=100);n++;
  return new Response(soap('TrackingRequest',richiesti.map(t=>`<TrackingResult><TrackingMBE>${t}</TrackingMBE><TrackingStatus>NOT_AVAILABLE</TrackingStatus><CourierTracking>000987</CourierTracking></TrackingResult>`).join('')));
 });const risultati=await c.tracking(ids);assert.equal(n,2);assert.equal(risultati.length,101);assert.equal(risultati[0].tracking_corriere,'000987');
});
test('autenticazione, errori e limiti non espongono credenziali o corpo remoto',async()=>{
 for(const status of [401,403,429,500]){const c=creaClientMbe('utente',chiave,async()=>new Response(chiave,{status}));await assert.rejects(c.tracking([codice(1)]),e=>e instanceof ErroreMbe&&!e.message.includes(chiave));}
 const c=creaClientMbe('utente',chiave,async()=>{throw new Error(chiave);});await assert.rejects(c.tracking([codice(1)]),e=>e instanceof ErroreMbe&&!e.message.includes(chiave));
 assert.throws(()=>creaClientMbe('utente:altro',chiave),ErroreMbe);
 const grande=creaClientMbe('utente',chiave,async()=>new Response('x'.repeat(4*1024*1024+1)));await assert.rejects(grande.tracking([codice(1)]),ErroreMbe);
});
test('XML malformato, DTD, correlazione, date, pagine o codici incerti vengono rifiutati',()=>{
 for(const xml of ['<bad>',`<!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]>${pagina(1,1,spedizione(1))}`,pagina(1,1,spedizione(1),'altra-correlazione')])assert.throws(()=>contenitoreMbe(xml,'ShipmentsListV3Request',id),ErroreMbe);
 for(const xml of [pagina(1,1,spedizione(1)).replace('2026-10-15','2026-02-30'),pagina(1,1,spedizione(1)).replace('<TotalPages>1</TotalPages>',''),pagina(1,1,spedizione(1)).replace(codice(1),'')])assert.throws(()=>paginaMbe(contenitoreMbe(xml,'ShipmentsListV3Request',id),1),ErroreMbe);
});
test('elenco vuoto esplicito è valido; pagine o risultati non univoci restano bloccati',async()=>{
 const vuoto=paginaMbe(contenitoreMbe(pagina(1,0,''),'ShipmentsListV3Request',id),1);assert.deepEqual(vuoto.spedizioni,[]);
 let n=0;const c=creaClientMbe('utente',chiave,async(_url,init)=>{const ref=String(init?.body).match(/<InternalReferenceID>([^<]+)</)![1];return new Response(pagina(++n,2,spedizione(1),ref));});
 await assert.rejects(c.spedizioni('2026-09-16','2026-10-16'),ErroreMbe);
});
