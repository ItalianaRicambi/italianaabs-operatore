import {createHash} from 'node:crypto';
import {normalizzaOriginaliK,type OriginaleK} from '../originaliKeplero.ts';
import type {MessaggioKeplero} from '../kepleroMessages.ts';
import {labels,type Field,type Phase,type RequestEvidence} from './policy.ts';

export type Attachment = {messageId:string;sha256:string;bytes:Uint8Array;contentType:string};
export type LiveEvidence = {originals:OriginaleK[];attachments:Attachment[];fingerprint:string;startedAt:string;finishedAt:string};
const digest=(s:string|Uint8Array)=>createHash('sha256').update(s).digest('hex');
/** Non interpreta un riassunto AI come prova. Restituisce TUTTI gli originali e
 * i byte attuali degli allegati al revisore server. La lettura non è una revisione
 * semantica: il chiamante non può inferire allAttachmentsReviewed da questa funzione.
 */
export async function readLiveEvidence(session:string,read:()=>Promise<MessaggioKeplero[]>,request:typeof fetch=fetch,now=Date.now):Promise<LiveEvidence>{
 const startedAt=new Date(now()).toISOString();
 const originals=normalizzaOriginaliK(session,await read(),now());
 const attachments:Attachment[]=[];let total=0;
 for(const m of originals){
  if(m.tipo==='text'&&!m.testo.startsWith('attachment:'))continue;
  if(!m.testo.startsWith('attachment:'))throw new Error('followup_media_unreadable');
  const url=new URL(m.testo.slice(11));
  if(url.protocol!=='https:'||url.hostname!=='v2.api.keplero.ai'||url.port||url.username||url.password||url.hash
   ||url.search||!url.pathname.startsWith('/v2/session-attachments/'))throw new Error('followup_media_url_unverified');
  const r=await request(url.href,{cache:'no-store',redirect:'error',signal:AbortSignal.timeout(8000)});
  if(!r.ok){await r.body?.cancel();throw new Error('followup_media_unavailable');}
  const reader=r.body?.getReader();if(!reader)throw new Error('followup_media_empty');
  const chunks:Uint8Array[]=[];let size=0;
  try{for(;;){const c=await reader.read();if(c.done)break;size+=c.value.length;total+=c.value.length;
   if(size>8*1024*1024||total>32*1024*1024){await reader.cancel();throw new Error('followup_media_limit');}chunks.push(c.value);}
  }finally{reader.releaseLock();}
  if(!size)throw new Error('followup_media_empty');
  const bytes=new Uint8Array(Buffer.concat(chunks));
  attachments.push({messageId:m.id,bytes,sha256:digest(bytes),contentType:r.headers.get('content-type')||'application/octet-stream'});
 }
 // Detecta nuove risposte, cancellazioni/modifiche e mutazioni durante il download.
 const after=normalizzaOriginaliK(session,await read(),now());
 const signature=(items:OriginaleK[])=>digest(JSON.stringify(items.map(m=>[m.id,m.impronta])));
 if(signature(originals)!==signature(after))throw new Error('followup_conversation_changed');
 const fingerprint=digest(JSON.stringify([signature(after),attachments.map(a=>[a.messageId,a.sha256])]));
 return {originals:after,attachments,fingerprint,startedAt,finishedAt:new Date(now()).toISOString()};
}

/** Associa SOLO un testo mirato esatto già preparato per la pratica. Un flag
 * manuale "inviata", una data importata o un ultimo messaggio generico non bastano.
 * Nessun invio viene effettuato da questo registratore.
 */
export function findTargetedRequest(input:{practiceId:string;phase:Phase;exactText:string;fields:Field[];cutover:string},evidence:LiveEvidence):RequestEvidence|null{
 const cutoff=Date.parse(input.cutover);
 if(!Number.isFinite(cutoff)||!input.exactText.trim()||!input.fields.length||!input.fields.every(f=>Object.hasOwn(labels,f)))return null;
 // La provenienza e il significato del testo mirato restano responsabilità del
 // generatore/revisore server. Non accettare questi parametri da una route client.
 const matches=evidence.originals.filter(m=>m.direzione==='uscita'&&m.tipo==='text'&&m.testo===input.exactText
  &&Date.parse(m.data)>=cutoff&&Date.parse(m.data)<=Date.parse(evidence.startedAt));
 const last=matches.at(-1);if(!last)return null;
 const metadata=last.originale.metadata as Record<string,unknown>|undefined;
 const wa=last.originale.whatsapp_message as Record<string,unknown>|undefined;
 const proof=['delivered','read'].includes(String(wa?.status))
  ||(last.originale.sender_type==='user'&&metadata?.origin==='whatsapp_coexistence');
 if(!proof||evidence.originals.some(m=>m.data>=last.data&&m.direzione!=='uscita'))return null;
 return {practiceId:input.practiceId,phase:input.phase,messageId:last.id,sentAt:last.data,sourceFingerprint:last.impronta,deliveryConfirmed:true,fields:input.fields};
}
