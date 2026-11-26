import test from 'node:test';
import assert from 'node:assert/strict';
import {trackingMbeDaAggiornare,creaClientMbe,contenitoreMbe,paginaMbe,esitiMbe,ErroreMbe} from './mbe.ts';
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
test('elenco MBE con paese per esteso e tracking del singolo collo',()=>{
 const master=codice(1);
 const riga=spedizione(1).replace('<Country>IT</Country>','<Country>Italy</Country>')
  .replace('</TrackingInfo>',`<TrackingsMBE><TrackingMBE>${master}-01</TrackingMBE></TrackingsMBE></TrackingInfo>`);
 const risposta=contenitoreMbe(pagina(1,1,riga),'ShipmentsListV3Request',id);
 const [r]=paginaMbe(risposta,1).spedizioni;
 assert.equal(r.destinatario.paese,'Italy');
 assert.deepEqual(r.colli_mbe,[master+'-01']);
 assert.equal(r.tracking_mbe,master);
});
test('la diagnostica identifica la pagina e il campo senza esporne il valore',async()=>{
 const c=creaClientMbe('utente',chiave,async(_url,init)=>{
  const ref=String(init?.body).match(/<InternalReferenceID>([^<]+)</)![1];
  return new Response(pagina(1,1,spedizione(1).replace('2026-10-15','dato-riservato'),ref));
 });
 await assert.rejects(c.spedizioni('2026-09-16','2026-10-16'),e=>e instanceof ErroreMbe&&e.message.includes('pagina 1')&&e.message.includes('ShipmentInfo.Date')&&!e.message.includes('dato-riservato'));
});
test('un batch parziale riprende solo gli assenti; una risposta singola vale per il codice richiesto',async()=>{
 const ids=[codice(1),codice(2),codice(3)];
 const chiamate:string[][]=[];
 const c=creaClientMbe('utente',chiave,async(_url,init)=>{
  const gruppo=[...String(init?.body).matchAll(/<TrackingMBE>([^<]+)</g)].map(m=>m[1]);
  chiamate.push(gruppo);
  if(gruppo.length===3)return new Response(soap('TrackingRequest',`<TrackingResult><TrackingMBE>${ids[1]}</TrackingMBE><TrackingStatus>DELIVERED</TrackingStatus></TrackingResult>`));
  if(gruppo.length===2)return new Response(soap('TrackingRequest',''));
  return new Response(soap('TrackingRequest','<TrackingStatus>NOT_AVAILABLE</TrackingStatus>'));
 });
 const esiti=await c.tracking(ids);
 assert.deepEqual(chiamate,[ids,[ids[0],ids[2]],[ids[0]],[ids[2]]]);
 assert.deepEqual(esiti.map(x=>x.tracking_mbe).sort(),ids);
 assert.equal(esiti.find(x=>x.tracking_mbe===ids[1])?.stato,'DELIVERED');
});
test('un tracking singolo senza esito, o con identità diversa, impedisce il commit',async()=>{
 const c=creaClientMbe('utente',chiave,async()=>new Response(soap('TrackingRequest','')));
 await assert.rejects(c.tracking([codice(1),codice(2)]),/0 risultati su 1/);
 assert.throws(()=>esitiMbe({TrackingStatus:'DELIVERED',TrackingMBE:codice(2)},[codice(1)]),ErroreMbe);
});
test('gli esiti estranei o duplicati di un batch non entrano nel registro',async()=>{
 const ids=[codice(1),codice(2)];
 const esito=(id:string,stato:string)=>`<TrackingResult><TrackingMBE>${id}</TrackingMBE><TrackingStatus>${stato}</TrackingStatus></TrackingResult>`;
 for(const extra of [ids[0],codice(7)]){
  const c=creaClientMbe('utente',chiave,async(_url,init)=>{
   const richiesti=[...String(init?.body).matchAll(/<TrackingMBE>([^<]+)</g)].map(m=>m[1]);
   const contenuto=richiesti.length===2?[...ids,extra].map(id=>esito(id,'EXCEPTION')).join(''):esito(richiesti[0],'DELIVERED');
   return new Response(soap('TrackingRequest',contenuto));
  });
  const r=await c.tracking(ids);
  assert.deepEqual(r.map(x=>[x.tracking_mbe,x.stato]),ids.map(id=>[id,'DELIVERED']));
 }
});

test('controlla sempre i nuovi e gli aperti, e tutti i consegnati una volta al giorno',()=>{
 const consegnati=new Set(['D1','D2','D3']);
 const riletti:string[]=[];
 for(let turno=0;turno<96;turno++){
  const selezionati=trackingMbeDaAggiornare(['N','A','N',...consegnati],consegnati,turno*900000);
  assert.deepEqual(selezionati.filter(id=>!consegnati.has(id)),['N','A']);
  riletti.push(...selezionati.filter(id=>consegnati.has(id)));
 }
 assert.deepEqual(riletti.sort(),[...consegnati]);
});

test('un gruppo rifiutato viene verificato in parti; un rifiuto sul singolo resta un errore',async()=>{
 const ids=[codice(1),codice(2)];
 const ko=soap('TrackingRequest','<Errors><Error><ErrorCode>E001</ErrorCode><Description>dato da omettere</Description></Error></Errors>').replace('<Status>OK</Status>','<Status>ERROR</Status>');
 for(const singoloRifiutato of [false,true]){
  const chiamate:string[][]=[];
  const c=creaClientMbe('utente',chiave,async(_url,init)=>{
   const gruppo=[...String(init?.body).matchAll(/<TrackingMBE>([^<]+)</g)].map(m=>m[1]);
   chiamate.push(gruppo);
   if(gruppo.length>1 || (singoloRifiutato && gruppo[0]===ids[1]))return new Response(ko);
   return new Response(soap('TrackingRequest','<TrackingStatus>WAITING_DELIVERY</TrackingStatus>'));
  });
  if(singoloRifiutato)await assert.rejects(c.tracking(ids),e=>e instanceof ErroreMbe &&
   e.message.includes('E001') && e.message.includes(ids[1]) && !e.message.includes('dato da omettere'));
  else assert.deepEqual((await c.tracking(ids)).map(r=>r.tracking_mbe),ids);
  assert.deepEqual(chiamate,[ids,[ids[0]],[ids[1]]]);
 }
});

test('un TR_001 isolato non blocca il vicino, si risolve appena confermato; gli altri errori restano bloccanti',async()=>{
 const ids=[codice(7),codice(8)];
 let negativo='TR_001';
 const c=creaClientMbe('utente',chiave,async(_url,init)=>{
  const gruppo=[...String(init?.body).matchAll(/<TrackingMBE>([^<]+)</g)].map(m=>m[1]);
  if(gruppo.includes(ids[0]) && negativo)return new Response(soap('TrackingRequest','<Errors><Error><ErrorCode>'+negativo+'</ErrorCode></Error></Errors>').replace('<Status>OK</Status>','<Status>ERROR</Status>'));
  return new Response(soap('TrackingRequest','<TrackingStatus>DELIVERED</TrackingStatus>'));
 });
 const rifiutati=new Set<string>();
 assert.deepEqual((await c.tracking(ids,rifiutati)).map(t=>t.tracking_mbe),[ids[1]]);
 assert.deepEqual([...rifiutati],[ids[0]]);
 negativo='ALTRA_CAUSA';
 await assert.rejects(c.tracking([ids[0]],new Set()),/ALTRA_CAUSA/);
 negativo='';
 assert.equal((await c.tracking([...rifiutati],new Set()))[0].stato,'DELIVERED');
});
