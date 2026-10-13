import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizzaEmail, payloadEmail, esclusioneEmail, autorizzazioneEmail } from './richiesteEmail.ts';
const originale = {mailbox:'info@italianaabs.com',sender:'officina@example.com',subject:'Richiesta ABS',content:'Buongiorno, targa AB123CD, errore C2200. Foto in allegato.',conversation_id:'b3be5f5b-ece5-4c5e-90be-e39d856fe12f'};
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
