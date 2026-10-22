import {test} from 'node:test';
import assert from 'node:assert/strict';
import {normalizzaOriginaliK,pdfOriginaleK,improntaPdfOriginaleK} from './originaliKeplero.ts';
const sessione='11111111-1111-4111-8111-111111111111';
const base={id:101,session:sessione,timestamp:'2026-10-20 08:23:07.311628+00',content:'Ripariamo la nostra',type:'text',sender:'user',sender_type:null};
const ora=Date.parse('2026-10-20T14:00:00Z');
test('legge timestamp UTC originale e separa cliente, operatore e AI',()=>{
 const r=normalizzaOriginaliK(sessione,[base,{...base,id:2,sender:'assistant',sender_type:'user'},{...base,id:3,sender:'assistant'}],ora);
 assert.equal(r.find(m=>m.id==='101')?.data,'2026-10-20T08:23:07.311Z');
 assert.deepEqual(r.map(m=>m.direzione).sort(),['entrata','uscita','uscita']);
 assert.equal(r.filter(m=>m.candidato).length,1);
});
test('nessuna importazione con ID ripetuti, sessione differente, data futura o senza fuso',()=>{
 for(const msgs of [[base,base],[{...base,session:'altra'}],[{...base,timestamp:'2026-10-21 08:23:07+00'}],[{...base,timestamp:'2026-10-20 08:23:07'}],[{...base,timestamp:'2026-02-31 08:23:07+00'}]])assert.throws(()=>normalizzaOriginaliK(sessione,msgs,ora));
});
test('solo il PDF inviato manualmente con prova WhatsApp può essere confrontato automaticamente',()=>{
 const file={...base,type:'file',sender:'assistant',sender_type:'user',content:'attachment:https://v2.api.keplero.ai/v2/session-attachments/uuid-%24%24name%24%24-ZZ001AA.pdf'};
 assert.equal(normalizzaOriginaliK(sessione,[file],ora)[0].targa_pdf,null);
 assert.equal(normalizzaOriginaliK(sessione,[{...file,metadata:{origin:'whatsapp_coexistence',wa_message_id:'wamid.originale'}}],ora)[0].targa_pdf,'ZZ001AA');
 assert.equal(normalizzaOriginaliK(sessione,[{...file,sender_type:null,metadata:{origin:'whatsapp_coexistence',wa_message_id:'wamid.originale'}}],ora)[0].targa_pdf,null);
});
test('rileva intenzioni, revoche, fatture e pagamento senza trasformarli in consenso',()=>{
 const r=normalizzaOriginaliK(sessione,[{...base,content:'Vorrei fare lo scambio con uno rigenerato'},{...base,id:2,content:'Non confermo, annullo'},{...base,id:3,content:'Pagamento eseguito'},{...base,id:4,sender:'assistant',sender_type:'user',type:'file',content:'attachment:https://v2.api.keplero.ai/v2/session-attachments/a-Fattura-530.pdf'}],ora);
 assert.ok(r.every(m=>m.candidato));assert.equal(r.find(m=>m.id==='2')?.revoca,true);
});
test('la scelta colloquiale dello scambio viene segnalata senza acquisire un ordine',()=>{
 for(const content of ['Voglio fare programma scambio','Vogliamo fare il programma scambio','Desidero fare PS','Non voglio fare programma scambio','Voglio fare programma scambio se disponibile']){
  const [m]=normalizzaOriginaliK(sessione,[{...base,content}],ora);
  assert.equal(m.candidato,true,content);
  assert.equal(m.testo,content);
  assert.equal('ordine_confermato' in m,false);
 }
 assert.equal(normalizzaOriginaliK(sessione,[{...base,content:'Voglio fare una domanda'}],ora)[0].candidato,false);
});
test('PDF nome-targa solo su host e percorso fissi, senza query, credenziali o istruzioni',()=>{
 const buono='attachment:https://v2.api.keplero.ai/v2/session-attachments/uuid-%24%24name%24%24-ZZ001AA.pdf';
 assert.equal(pdfOriginaleK(buono)?.targa,'ZZ001AA');
 for(const value of [buono.replace('v2.api.keplero.ai','evil.test'),buono+'?token=x',buono.replace('/v2/session-attachments/','/v2/sessions/'),buono.replace('ZZ001AA.pdf','Fattura-530.pdf'),'testo '+buono])assert.equal(pdfOriginaleK(value),null);
});
test('download limitato e senza redirect; nessun segreto inviato al PDF',async()=>{
 const link='attachment:https://v2.api.keplero.ai/v2/session-attachments/uuid-%24%24name%24%24-ZZ001AA.pdf';
 let opt:RequestInit|undefined;
 const ok=await improntaPdfOriginaleK(link,(async(_url,o)=>{opt=o;return new Response('%PDF-documento');}) as typeof fetch);
 assert.match(ok||'',/^[a-f0-9]{64}$/);assert.equal(opt?.redirect,'error');assert.equal(opt?.headers,undefined);
 assert.equal(await improntaPdfOriginaleK(link,(async()=>new Response('HTML')) as typeof fetch),null);
 assert.equal(await improntaPdfOriginaleK(link,(async()=>new Response('%PDF-',{headers:{'content-length':String(4*1024*1024)}})) as typeof fetch),null);
});
test('le copie numerate mantengono la targa, senza accettare altri documenti o nomi ambigui',()=>{
 const prefix='attachment:https://v2.api.keplero.ai/v2/session-attachments/uuid-%24%24name%24%24-';
 for(const nome of ['ZZ001AA%20_1_.pdf','ZZ001AA%20(1).pdf','ZZ001AA(12).pdf']){
  const content=prefix+nome;
  assert.equal(pdfOriginaleK(content)?.targa,'ZZ001AA');
  const file={...base,sender:'assistant',sender_type:'user',type:'file',content,metadata:{origin:'whatsapp_coexistence'}};
  assert.equal(normalizzaOriginaliK(sessione,[file],ora)[0].targa_pdf,'ZZ001AA');
  assert.equal(normalizzaOriginaliK(sessione,[{...file,metadata:{}}],ora)[0].targa_pdf,null);
 }
 for(const nome of ['ZZ001AA _0_.pdf','ZZ001AA _1000_.pdf','ZZ001AA _1_ ZZ002AA.pdf','Pro-Forma-123_2026-Cliente-Test.pdf','ZZ001AA (1) (2).pdf','ZZ001AA _1_.pdf?token=x'])assert.equal(pdfOriginaleK(prefix+nome),null);
});
