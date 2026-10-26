import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizzaEmail, payloadEmail, esclusioneEmail, autorizzazioneEmail, praticaDaEsitoEmail } from './richiesteEmail.ts';
const originale = {mailbox:'info@italianaabs.com',sender:'officina@example.com',subject:'Richiesta ABS',content:'Buongiorno, targa AB123CD, errore C2200. Foto in allegato.',conversation_id:'b3be5f5b-ece5-4c5e-90be-e39d856fe12f'};
test('la casella ordini conserva il messaggio senza generare pratiche o attestare pagamenti',()=>{
 const ordini=normalizzaEmail({...originale,mailbox:' ORDINI@ITALIANAABS.COM ',subject:'Ordine #1003 pagato',content:'Confermo il preventivo PS. Pagamento completato. Targa AB123CD.'});
 assert.equal(ordini.mailbox,'ordini@italianaabs.com');
 assert.equal(payloadEmail(ordini).operativo,false);
 assert.equal(payloadEmail(normalizzaEmail({...ordini,mailbox:'info@italianaabs.com'})).operativo,true);
 assert.equal(ordini.content,'Confermo il preventivo PS. Pagamento completato. Targa AB123CD.');
 assert.notEqual(ordini.fingerprint,normalizzaEmail({...ordini,mailbox:'info@italianaabs.com'}).fingerprint);
 assert.equal(ordini.fingerprint,normalizzaEmail({...ordini}).fingerprint);
});
test('identità stabile sui retry; messaggi diversi nello stesso thread restano distinti',()=>{
 const e=normalizzaEmail(originale); assert.equal(e.fingerprint,normalizzaEmail({...originale}).fingerprint);
 assert.notEqual(e.fingerprint,normalizzaEmail({...originale,content:'Confermo il preventivo'}).fingerprint);
 assert.notEqual(e.fingerprint,normalizzaEmail({...originale,sender:'altro@example.com'}).fingerprint);
});
test('rifiuta variabili non risolte e caselle diverse',()=>{
 assert.throws(()=>normalizzaEmail({...originale,content:'{{trigger.email_content}}'}));
 assert.throws(()=>normalizzaEmail({...originale,mailbox:'altro@example.com'}));
 assert.throws(()=>normalizzaEmail({...originale,conversation_id:'anonimo'}));
});
test('il collaudo è registrabile ma non diventa una pratica cliente',()=>{
 assert.ok(esclusioneEmail(normalizzaEmail({...originale,subject:'TEST EMAIL — prova',content:'Collaudo interno — caso simulato'})));
 assert.equal(esclusioneEmail(normalizzaEmail({...originale,content:'Test al banco richiesto per ABS'})),null);
});
test('dati letterali, targhe ambigue e allegati non trasmessi restano da verificare',()=>{
 const p=payloadEmail(normalizzaEmail(originale)); assert.equal(p.body.targa,'AB123CD'); assert.deepEqual(p.body.dtc,['C2200']);
 assert.equal(p.body.email_allegati_da_verificare,true); assert.equal(p.body.dati_completi,false);
 assert.equal(payloadEmail(normalizzaEmail({...originale,content:originale.content+' Targa EF456GH.'})).body.targa,null);
 assert.equal(payloadEmail(normalizzaEmail({...originale,subject:'Confermiamo il preventivo',content:'Confermiamo.'})).operativo,true);
});
test('autorizzazione fail closed',()=>{
 assert.equal(autorizzazioneEmail('a','a'),true); assert.equal(autorizzazioneEmail('a','b'),false); assert.equal(autorizzazioneEmail(null,'a'),false); assert.equal(autorizzazioneEmail('a',undefined),false);
});
test('le conferme nella cronologia citata non diventano una nuova accettazione',()=>{
 const p=payloadEmail(normalizzaEmail({...originale,content:'Ho una domanda.\nIl 12 ottobre Mario ha scritto:\nConfermo il preventivo. Targa AB123CD.'}));
 assert.equal(p.body.ultimo_messaggio_cliente,'Ho una domanda.');assert.equal(p.body.targa,null);
 const html=payloadEmail(normalizzaEmail({...originale,content:'<p>Ho una domanda.</p><blockquote>Confermo.</blockquote>'}));
 assert.doesNotMatch(html.body.ultimo_messaggio_cliente,/Confermo/);
});
test('collega la pratica dal risultato effettivo di live; conflitti restano da verificare',()=>{
 const id='78b097ef-1e89-46a0-b443-a59af5b6c7a7';
 assert.equal(praticaDaEsitoEmail({ok:true,result:{ok:true,pratica_id:id}}),id);
 assert.equal(praticaDaEsitoEmail({pratica_id:id}),id);
 assert.equal(praticaDaEsitoEmail({ok:true,result:{pratica_id:'non valido'}}),null);
 assert.equal(praticaDaEsitoEmail({pratica_id:id,result:{pratica_id:originale.conversation_id}}),null);
 assert.equal(praticaDaEsitoEmail(null),null);
});
test('la risposta con sola targa viene acquisita senza usare la citazione',()=>{
 const risposta={...originale,subject:'Re: Riparazione centralina ABS',content:'DF271RF.\nInviato da iPhone\n\n> Il giorno 14 ott ha scritto:\n> Targa AB123CD'};
 assert.equal(payloadEmail(normalizzaEmail(risposta)).body.targa,'DF271RF');
 assert.equal(payloadEmail(normalizzaEmail({...risposta,content:'DF271RF\nAB123CD'})).body.targa,null);
 assert.equal(payloadEmail(normalizzaEmail({...risposta,content:'Codice componente DF271RF'})).body.targa,null);
 assert.equal(payloadEmail(normalizzaEmail(risposta)).body.descrizione_guasto,null);
 assert.equal(payloadEmail(normalizzaEmail({...risposta,content:'Targa: DF271RF.\nInviato da iPhone'})).body.descrizione_guasto,null);
 assert.match(payloadEmail(normalizzaEmail({...risposta,content:'Targa DF271RF, non frena la ruota anteriore.'})).body.descrizione_guasto||'',/non frena/);
});
test('gli allegati soltanto citati nella vecchia email non diventano nuovi file ricevuti',()=>{
 const p=payloadEmail(normalizzaEmail({...originale,content:'DF271RF.\nIl giorno 14 ottobre Mario ha scritto:\nFoto ABS: https://v2.api.keplero.ai/vecchio.pdf'}));
 assert.deepEqual(p.body.allegati,[]);
 const html=payloadEmail(normalizzaEmail({...originale,content:'<p>Foto ABS</p><img src="https://v2.api.keplero.ai/nuovo.jpg"><blockquote><a href="https://v2.api.keplero.ai/vecchio.pdf">Vecchio file</a></blockquote>'}));
 assert.deepEqual(html.body.allegati,['https://v2.api.keplero.ai/nuovo.jpg']);
});
