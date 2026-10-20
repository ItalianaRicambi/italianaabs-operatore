import test from "node:test";
import assert from "node:assert/strict";
import {leggiIdConversazioneKeplero} from "./identitaConversazione.ts";
const session="11111111-1111-4111-8111-111111111111";
test("legge il SessionId nell'intestazione originale di K senza dipendere da targa o flusso",()=>{
 const headers=new Headers({"X-Keplero-SessionId":session});
 for(const body of [{tipo_flusso:"assistenza"},{tipo_flusso:"commerciale",targa:"TST100"},{}])
  assert.equal(leggiIdConversazioneKeplero(body,headers),session);
});
test("restano compatibili gli identificativi nel payload e le intestazioni precedenti",()=>{
 for(const campo of ["conversation_id","keplero_conversation_id","session_id","conversationId","chat_id","chatId","thread_id","threadId"])
  assert.equal(leggiIdConversazioneKeplero({[campo]:session},new Headers()),session);
 for(const campo of ["x-keplero-conversation-id","x-conversation-id","x-session-id"])
  assert.equal(leggiIdConversazioneKeplero({},new Headers({[campo]:session})),session);
});
test("il riferimento esplicito conserva la precedenza; campi vuoti usano l'intestazione",()=>{
 const h=new Headers({"X-Keplero-SessionId":session});
 assert.equal(leggiIdConversazioneKeplero({session_id:"body-session"},h),"body-session");
 assert.equal(leggiIdConversazioneKeplero({conversation_id:"  ",session_id:null},h),session);
});
test("numero del canale e autorizzazione non diventano identificativi di conversazione",()=>{
 assert.equal(leggiIdConversazioneKeplero({},new Headers({"X-Keplero-Channel-Identifier":"+390000000000","Authorization":"Bearer test"})),"");
});
