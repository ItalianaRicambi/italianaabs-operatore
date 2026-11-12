import {templates, type Phase} from './policy.ts';
import {normalizzaOriginaliK} from '../originaliKeplero.ts';
import type {MessaggioKeplero} from '../kepleroMessages.ts';

/** Contratto supporto Keplero #18399, 09/11/2026 18:43 UTC.
 * Solo il wrapper server possiede la chiave. Nessun retry, redirect o coda locale.
 */
export const BOT = '2aef20d3-5ef8-4c81-8f21-bd450f22960c';
export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export type SendInput = {phase:Phase; to:string; session:string; variables:[string,string]};
export type SendResult = {kind:'accepted';session:string} | {kind:'rejected';code:string} | {kind:'ambiguous';code:string};
export function oneLine(s:string):string {return s.replace(/\s+/g,' ').trim();}
export function validateSend(input:SendInput):void {
 if(!Object.hasOwn(templates,input.phase)||!/^\+[1-9]\d{7,14}$/.test(input.to)||!UUID.test(input.session)
  ||!Array.isArray(input.variables)||input.variables.length!==2||!/^ABS-\d{6,}$/.test(input.variables[0])
  ||typeof input.variables[1]!=='string'||!oneLine(input.variables[1])||input.variables[1].length>1000)
  throw new Error('followup_send_invalid');
}
async function smallJson(response:Response):Promise<Record<string,unknown>> {
 const reader=response.body?.getReader();if(!reader)throw new Error('empty');
 let size=0;const chunks:Uint8Array[]=[];
 try{for(;;){const c=await reader.read();if(c.done)break;size+=c.value.length;
  if(size>16_384){await reader.cancel();throw new Error('large');}chunks.push(c.value);}
  const data:unknown=JSON.parse(Buffer.concat(chunks).toString());
  if(!data||typeof data!=='object'||Array.isArray(data))throw new Error('invalid');
  return data as Record<string,unknown>;
 }finally{reader.releaseLock();}
}
export async function sendTemplate(input:SendInput,apiKey:string|undefined,request:typeof fetch=fetch):Promise<SendResult>{
 validateSend(input);
 const token=apiKey?.trim().replace(/^Bearer[ \t]+/i,'').trim();
 if(!token||/[\r\n]/.test(token))throw new Error('followup_transport_unconfigured');
 try{
  const response=await request(`https://v2.api.keplero.ai/conversations/${BOT}/send-template`,{
   method:'POST',headers:{Authorization:`Bearer ${token}`,'Content-Type':'application/json'},
   body:JSON.stringify({channel:'whatsapp',name:templates[input.phase],language:'it',to:input.to,variables:input.variables.map(oneLine)}),
   cache:'no-store',redirect:'error',signal:AbortSignal.timeout(60_000),
  });
  // Solo un 400 documentato è una prova negativa. Proxy, 5xx e risposte illeggibili sono ambigui.
  const data=await smallJson(response);
  if(response.status===400&&(data.message==='Failed to send template'||data.message==='Invalid phone number'))
   return {kind:'rejected',code:'provider_rejected'};
  if(response.status===200&&data.sessionId===input.session)return {kind:'accepted',session:input.session};
  return {kind:'ambiguous',code:'response_unverified'};
 }catch{return {kind:'ambiguous',code:'network_or_response_error'};}
}

export type Attempt = SendInput & {
 startedAt:string; beforeIds:string[]; expectedText:string;
};
export type Receipt = {messageId:string;providerMessageId:string;sentAt:string;status:string};
/** Il solo numero pratica non identifica l'invio. Servono testo esatto, finestra
 * temporale, origine documentata, conversazione, ID nuovi e UN solo candidato.
 * Nessun match non significa "non inviato" e non abilita mai un retry.
 */
export function reconcile(attempt:Attempt,messages:MessaggioKeplero[],now:number):Receipt|null {
 validateSend(attempt);
 const start=Date.parse(attempt.startedAt);
 if(!Number.isFinite(start)||start>now||!attempt.expectedText||!Array.isArray(attempt.beforeIds))return null;
 const originals=normalizzaOriginaliK(attempt.session,messages,now);
 const before=new Set(attempt.beforeIds);
 const matches=originals.filter(m=>!before.has(m.id)&&Date.parse(m.data)>=Math.floor(start/1000)*1000
  &&Date.parse(m.data)<=Math.min(now,start+60_000)&&oneLine(m.testo)===oneLine(attempt.expectedText));
 if(matches.length!==1)return null;
 const m=matches[0],raw=m.originale;
 const metadata=raw.metadata as Record<string,unknown>|undefined;
 const origin=metadata?.templateOrigin as Record<string,unknown>|undefined;
 const wa=raw.whatsapp_message as Record<string,unknown>|undefined;
 const id=metadata?.wa_message_id;
 if(m.direzione!=='uscita'||raw.sender_type!=='operator'||origin?.type!=='manual_operator'
  ||typeof id!=='string'||!id.trim()||id.length>300||!['sent','delivered','read'].includes(String(wa?.status)))return null;
 return {messageId:m.id,providerMessageId:id,sentAt:m.data,status:String(wa?.status)};
}
