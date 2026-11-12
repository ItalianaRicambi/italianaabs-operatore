import {test} from 'node:test';
import assert from 'node:assert/strict';
import {prepareReminder,shouldEscalate,nextOpening,isOpen,type Context,type Calendar,type Field} from './policy.ts';
const now=Date.parse('2026-11-10T10:00:00Z');
const calendar:Calendar={confirmedThrough:'2027-12-31',closures:[{from:'2026-12-08',through:'2026-12-08'}]};
function context(at=now):Context {
 return {
  enabledAfter:'2026-11-09T00:00:00Z',calendar,
  request:{practiceId:'synthetic-practice',phase:'preventivo',messageId:'101',sentAt:'2026-11-09T10:00:00Z',sourceFingerprint:'a'.repeat(64),deliveryConfirmed:true,fields:['foto','targa']},
  ledger:{state:'none',sentAt:null,messageId:null},
  snapshot:{practiceId:'synthetic-practice',practiceNumber:'ABS-999999',channel:'whatsapp',phase:'preventivo',commercialState:'raccolta_dati',completeness:'dati_mancanti',quoteIssued:false,acceptedOrder:false,invoiceOrProformaIssued:false,closedOrDeclined:false,operatorBlocked:false,responsePendingReview:false,fiscalRegistryChecked:false,fiscalRegistryAmbiguous:false,missing:['foto'],readStartedAt:new Date(at-1000).toISOString(),readFinishedAt:new Date(at).toISOString(),allOriginalsRead:true,allAttachmentsReviewed:true,originalRequestPresent:true,originalRequestUnchanged:true,customerReplyAtOrAfterRequest:false,unknownDirectionAfterRequest:false,sourceFingerprint:'b'.repeat(64)},
 };
}
function fiscal(at=now):Context {
 const c=context(at);c.request.phase=c.snapshot.phase='fatturazione';c.request.fields=c.snapshot.missing=['cap'];c.snapshot.acceptedOrder=true;c.snapshot.commercialState='ordine_acquisito';c.snapshot.fiscalRegistryChecked=true;return c;
}
function stopped(c:Context,reason:string,at=now) {assert.deepEqual(prepareReminder(c,at),{kind:'stop',reason});}
const iso=(s:string)=>new Date(s).getTime();
test('invio esattamente a 24h, template e soli campi ancora mancanti',()=>{
 const c=context();const result=prepareReminder(c,now);assert.equal(result.kind,'ready');
 if(result.kind==='ready'){assert.deepEqual(result.variables,['ABS-999999','foto leggibili del componente']);assert.equal(result.template,'italianaabs_dati_preventivo_24h');}
 const early=context(now-1);assert.deepEqual(prepareReminder(early,now-1),{kind:'wait',at:'2026-11-10T10:00:00.000Z'});
});
test('data assente, invio non confermato e richiesta storica non autorizzano recupero',()=>{
 for(const sentAt of [null,'2026-11-09T10:00:00','2026-02-31T10:00:00Z','non-data']){const c=context();c.request.sentAt=sentAt;stopped(c,'request_send_unverified');}
 const c=context();c.request.deliveryConfirmed=false;stopped(c,'request_send_unverified');
 c.request.deliveryConfirmed=true;c.enabledAfter='2026-11-09T11:00:00Z';stopped(c,'historical_request_excluded');
 c.enabledAfter=null;stopped(c,'historical_request_excluded');
});
test('weekend, pausa pranzo e venerdì pomeriggio vanno alla prima apertura',()=>{
 for(const [input,expected] of [
  ['2026-11-09T11:30:00Z','2026-11-09T13:00:00Z'],
  ['2026-11-13T12:30:00Z','2026-11-16T08:00:00Z'],
  ['2026-11-14T09:00:00Z','2026-11-16T08:00:00Z'],
  ['2026-11-15T09:00:00Z','2026-11-16T08:00:00Z'],
  ['2026-11-09T07:59:59.999Z','2026-11-09T08:00:00Z'],
 ])assert.equal(nextOpening(iso(input),calendar),iso(expected));
});
test('chiusura aziendale e calendario non confermato bloccano invio',()=>{
 assert.equal(nextOpening(iso('2026-12-08T10:00:00Z'),calendar),iso('2026-12-09T08:00:00Z'));
 const c=context();c.calendar={...calendar,confirmedThrough:'2026-11-09'};stopped(c,'calendar_unverified');
 assert.equal(nextOpening(now,{...calendar,closures:[{from:'invalid',through:'2026-11-30'}]}),null);
});
test('ora legale/solare: il timer resta 24h effettive, la finestra segue Roma',()=>{
 assert.equal(nextOpening(iso('2026-03-28T11:00:00Z'),calendar),iso('2026-03-30T07:00:00Z'));
 assert.equal(nextOpening(iso('2026-10-24T11:00:00Z'),calendar),iso('2026-10-26T08:00:00Z'));
 assert.equal(isOpen(iso('2026-07-13T07:00:00Z'),calendar),true);
 assert.equal(isOpen(iso('2026-11-09T07:00:00Z'),calendar),false);
});
test('worker in ritardo fuori fascia attende nuovamente un’apertura',()=>{
 const at=iso('2026-11-10T18:00:00Z');const c=context(at);
 assert.deepEqual(prepareReminder(c,at),{kind:'wait',at:'2026-11-11T08:00:00.000Z'});
});
test('ogni risposta o allegato successivo sospende il timer della richiesta',()=>{
 for(const key of ['responsePendingReview','customerReplyAtOrAfterRequest','unknownDirectionAfterRequest'] as const){const c=context();c.snapshot[key]=true;stopped(c,'response_to_review');}
});
test('nessun invio su originali/allegati incompleti o letti troppo presto',()=>{
 for(const key of ['allOriginalsRead','allAttachmentsReviewed'] as const){const c=context();c.snapshot[key]=false;stopped(c,'live_review_incomplete_or_stale');}
 const c=context();c.snapshot.readStartedAt=new Date(now-15_001).toISOString();stopped(c,'live_review_incomplete_or_stale');
 c.snapshot.readStartedAt=new Date(now).toISOString();c.snapshot.readFinishedAt=new Date(now+1).toISOString();stopped(c,'live_review_incomplete_or_stale');
});
test('richiesta cambiata, cancellata o di un’altra pratica viene esclusa',()=>{
 for(const key of ['originalRequestPresent','originalRequestUnchanged'] as const){const c=context();c.snapshot[key]=false;stopped(c,'request_changed_or_absent');}
 const c=context();c.snapshot.practiceId='other';stopped(c,'association_unverified');
});
test('rinuncia, chiusura, blocco operatore, fattura/proforma fermano entrambe le fasi',()=>{
 for(const factory of [context,fiscal])for(const [key,reason] of [
  ['closedOrDeclined','closed'],['operatorBlocked','operator_block'],['invoiceOrProformaIssued','already_invoiced'],
 ] as const){const c=factory();c.snapshot[key]=true;stopped(c,reason);}
});
test('preventivo già emesso o ordine acquisito escludono il primo reminder',()=>{
 for(const key of ['quoteIssued','acceptedOrder'] as const){const c=context();c.snapshot[key]=true;stopped(c,'prequote_phase_ended');}
 const c=context();c.snapshot.completeness='dati_integrati_da_verificare';stopped(c,'prequote_phase_ended');
});
test('fatturazione richiede ordine e verifica anagrafica, senza ambiguità',()=>{
 const c=fiscal();assert.equal(prepareReminder(c,now).kind,'ready');
 c.snapshot.fiscalRegistryChecked=false;stopped(c,'fiscal_registry_to_verify');
 c.snapshot.fiscalRegistryChecked=true;c.snapshot.fiscalRegistryAmbiguous=true;stopped(c,'fiscal_registry_to_verify');
 c.snapshot.fiscalRegistryAmbiguous=false;c.snapshot.acceptedOrder=false;stopped(c,'order_not_accepted');
});
test('campi ignoti, di altra fase e verifica anagrafica non finiscono nel template',()=>{
 const c=fiscal();c.snapshot.missing=c.request.fields=['verifica_anagrafica' as Field];stopped(c,'new_targeted_request_required');
 c.snapshot.missing=c.request.fields=['foto'];stopped(c,'fields_wrong_phase');
});
test('dati completi fermano invio; nuovi campi richiedono una richiesta mirata',()=>{
 const c=context();c.snapshot.missing=[];stopped(c,'data_complete');
 c.snapshot.missing=['diagnosi'];stopped(c,'new_targeted_request_required');
});
test('risposta parziale non azzera da sola il timer: serve un nuovo invio verificato',()=>{
 const c=context();c.snapshot.customerReplyAtOrAfterRequest=true;stopped(c,'response_to_review');
 c.request={...c.request,messageId:'102',sentAt:'2026-11-10T09:00:00Z',fields:['foto']};c.snapshot.customerReplyAtOrAfterRequest=false;
 assert.deepEqual(prepareReminder(c,now),{kind:'wait',at:'2026-11-11T09:00:00.000Z'});
});
test('claim, invio, timeout e annullamento consumano lo stesso slot pratica/fase',()=>{
 for(const state of ['claimed','sent','ambiguous','cancelled'] as const){const c=context();c.ledger.state=state;stopped(c,'reminder_already_claimed');c.request.messageId='new';stopped(c,'reminder_already_claimed');}
});
test('48h dopo invio confermato: solo escalation operatore, mai secondo reminder',()=>{
 const at=iso('2026-11-12T10:00:00Z');const c=context(at);c.ledger={state:'sent',sentAt:'2026-11-10T10:00:00Z',messageId:'provider-101'};
 assert.equal(shouldEscalate(c,at),true);stopped(c,'reminder_already_claimed',at);
 assert.equal(shouldEscalate(c,at-1),false);
 c.snapshot.customerReplyAtOrAfterRequest=true;assert.equal(shouldEscalate(c,at),false);
 c.snapshot.customerReplyAtOrAfterRequest=false;c.ledger.state='ambiguous';assert.equal(shouldEscalate(c,at),false);
});
test('nuova richiesta dopo dati parziali rinvia escalation senza riaprire invio',()=>{
 const at=iso('2026-11-12T10:00:00Z');const c=context(at);c.ledger={state:'sent',sentAt:'2026-11-10T10:00:00Z',messageId:'provider-101'};
 c.request.sentAt='2026-11-11T10:00:00Z';assert.equal(shouldEscalate(c,at),false);stopped(c,'reminder_already_claimed',at);
});

test('un flag mancante non viene interpretato come esito negativo verificato',()=>{
 const c=context();c.snapshot.invoiceOrProformaIssued=undefined as unknown as boolean;
 stopped(c,'evidence_unverified');
});

test('both follow-up phases honor a verified date and resume at the first business opening',()=>{
 for (const make of [context,fiscal]) {
  const monday=iso('2026-11-16T08:00:00Z');
  for (const at of [now,monday]) {
   const c=make(at);
   c.snapshot.customerReplyAtOrAfterRequest=true;
   c.snapshot.customerDeferral={notBefore:'2026-11-13T23:00:00.000Z',
    messages:[{id:'reply',fingerprint:'c'.repeat(64)}],conversationFingerprint:c.snapshot.sourceFingerprint};
   const result=prepareReminder(c,at);
   if (at===now) assert.deepEqual(result,{kind:'wait',at:'2026-11-16T08:00:00.000Z'});
   else assert.equal(result.kind,'ready');
   const missing=c.snapshot.missing;
   c.snapshot.missing=[];
   stopped(c,'data_complete',at);
   c.snapshot.missing=missing;
   c.snapshot.customerDeferral.conversationFingerprint='d'.repeat(64);
   stopped(c,'response_to_review',at);
  }
 }
});
