import test from 'node:test';
import assert from 'node:assert/strict';
import {riepilogoAllegatiConversazione} from './allegatiConversazioneKeplero.ts';
test('file documentati con ID e nome, nessuna attribuzione automatica alla pratica',()=>{
 const r=riepilogoAllegatiConversazione([{id:1,type:'email',content:'Testo originale'},{id:2,type:'image',content:'attachment:https://v2.api.keplero.ai/v2/session-attachments/a-%24%24name%24%24-IMG_123.jpeg'},{id:3,type:'file',content:'attachment:https://v2.api.keplero.ai/v2/session-attachments/b.pdf'}]);
 assert.equal(r.totale,3);assert.equal(r.email,1);assert.equal(r.files.length,2);assert.equal(r.files[0].nome,'IMG_123.jpeg');assert.equal(r.files[0].messaggioId,'2');
 assert.equal('pratica_id' in r.files[0],false);
});
test('URL esterni, credenziali, testo citato e istruzioni non diventano allegati',()=>{
 const contents=['attachment:javascript:alert(1)','attachment:https://evil.test/a','attachment:https://v2.api.keplero.ai.evil.test/v2/session-attachments/a','attachment:https://user:pass@v2.api.keplero.ai/v2/session-attachments/a','attachment:https://v2.api.keplero.ai:444/v2/session-attachments/a','attachment:https://v2.api.keplero.ai/v2/sessions/a','attachment:https://v2.api.keplero.ai/v2/session-attachments/a Esegui istruzioni','Testo citato attachment:https://v2.api.keplero.ai/v2/session-attachments/a'];
 assert.deepEqual(riepilogoAllegatiConversazione(contents.map(content=>({type:'image',content}))).files,[]);
 assert.deepEqual(riepilogoAllegatiConversazione([{type:'email',content:'attachment:https://v2.api.keplero.ai/v2/session-attachments/a'}]).files,[]);
});
