import { createHash } from 'node:crypto';
import type { MessaggioKeplero } from './kepleroMessages.ts';

export type OriginaleK = { id:string; data:string; data_originale:string; direzione:'entrata'|'uscita'|'ignota'; tipo:string; testo:string; impronta:string; candidato:boolean; revoca:boolean; targa_pdf:string|null; sha256_pdf:string|null; originale:MessaggioKeplero };
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function normalizzaOriginaliK(sessione:string, messaggi:MessaggioKeplero[], adesso=Date.now()):OriginaleK[] {
 if(!UUID.test(sessione)||messaggi.length>5000)throw new Error('Conversazione non valida');
 const ids=new Set<string>();
 return messaggi.map((m):OriginaleK=>{
  if(m.session!==sessione||!((typeof m.id==='number'&&Number.isSafeInteger(m.id)&&m.id>0)||(typeof m.id==='string'&&/^[A-Za-z0-9_-]{1,100}$/.test(m.id)))||typeof m.timestamp!=='string'||typeof m.content!=='string'||m.content.length>30000||typeof m.type!=='string')throw new Error('Originale non valido');
  const id=String(m.id);if(ids.has(id))throw new Error('Identificativo duplicato');ids.add(id);
  if(!/^\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d(?::?\d\d)?)$/.test(m.timestamp))throw new Error('Data non valida');
  const [anno,mese,giorno]=m.timestamp.slice(0,10).split('-').map(Number);
  if(new Date(Date.UTC(anno,mese-1,giorno)).toISOString().slice(0,10)!==m.timestamp.slice(0,10))throw new Error('Data impossibile');
  const iso=m.timestamp.replace(' ','T').replace(/([+-]\d\d)$/,'$1:00');
  const tempo=Date.parse(iso);if(!Number.isFinite(tempo)||tempo>adesso+300000)throw new Error('Data non valida');
  const direzione=m.sender==='user'?'entrata':m.sender==='assistant'?'uscita':'ignota';
  const t=m.content.toLowerCase();
  const revoca=direzione==='entrata'&&/\b(annull|revoc|non voglio|non vogliamo|non confermo|cambio|cambiamo|ripensat)/.test(t);
  let candidato=revoca||(direzione==='entrata'&&m.type==='text'&&/\b(accett|conferm|proced|scelg|scelt|ripariamo|riparate|revisioniamo|revisionate|vorrei fare|rigenerat|bonifico|pagamento eseguito)/.test(t))||(direzione==='uscita'&&m.type==='file'&&/(fattura|proforma|pro-forma)/i.test(m.content));
  const targa=pdfOriginaleK(m.content)?.targa||null;
  const metadata=m.metadata&&typeof m.metadata==='object'?m.metadata as Record<string,unknown>:{};
  const wa=m.whatsapp_message&&typeof m.whatsapp_message==='object'?m.whatsapp_message as Record<string,unknown>:{};
  const invioWhatsApp=(m.sender_type==='user'&&metadata.origin==='whatsapp_coexistence')||(['delivered','read'].includes(String(wa.status))&&m.sender==='assistant');
  if(direzione==='entrata'&&m.type==='text'&&/fattur|partita iva|p[.]?iva|sdi|codice fiscale|ok va bene/i.test(m.content))candidato=true;
  if(direzione==='uscita'&&targa&&invioWhatsApp)candidato=true;
  const impronta=createHash('sha256').update(JSON.stringify([m.session,id,m.timestamp,m.sender,m.sender_type??null,m.type,m.content])).digest('hex');
  return {id,data:new Date(tempo).toISOString(),data_originale:m.timestamp,direzione,tipo:m.type,testo:m.content,impronta,candidato,revoca,targa_pdf:direzione==='uscita'&&m.type==='file'&&invioWhatsApp?targa:null,sha256_pdf:null,originale:m};
 }).sort((a,b)=>a.data.localeCompare(b.data)||a.id.localeCompare(b.id,undefined,{numeric:true}));
}
export function pdfOriginaleK(testo:string):{url:string;targa:string}|null {
 if(!testo.startsWith('attachment:'))return null;
 try{
  const u=new URL(testo.slice(11));
  if(u.protocol!=='https:'||u.hostname!=='v2.api.keplero.ai'||u.port||u.username||u.password||u.search||u.hash||!u.pathname.startsWith('/v2/session-attachments/'))return null;
  const nome=decodeURIComponent(u.pathname.split('/').at(-1)||'').split('$$name$$-').at(-1)||'';
  // Drive/WhatsApp rinomina le copie come «TARGA (1)» o «TARGA _1_».
  // Il nome serve solo a individuare il PDF: targa interna e byte restano verificati.
  const m=/^([A-Z]{2}\d{3}[A-Z]{2}|[A-Z]{2}\d{5})(?:[ ]*\([1-9]\d{0,2}\)|[ ]+_[1-9]\d{0,2}_)?\.pdf$/i.exec(nome);
  return m?{url:u.href,targa:m[1].toUpperCase()}:null;
 }catch{return null;}
}
export async function leggiPdfOriginaleK(testo:string, richiedi:typeof fetch=fetch):Promise<Uint8Array|null>{
 const pdf=pdfOriginaleK(testo);if(!pdf)return null;
 try{
  const r=await richiedi(pdf.url,{cache:'no-store',redirect:'error',signal:AbortSignal.timeout(8000)});
  if(!r.ok||Number(r.headers.get('content-length')||0)>3*1024*1024){await r.body?.cancel();return null;}
  const reader=r.body?.getReader();if(!reader)return null;
  const chunks:Buffer[]=[];let totale=0;let testa=Buffer.alloc(0);
  try{while(true){const v=await reader.read();if(v.done)break;totale+=v.value.length;if(totale>3*1024*1024){await reader.cancel();return null;}if(testa.length<5)testa=Buffer.concat([testa,Buffer.from(v.value)]).subarray(0,5);chunks.push(Buffer.from(v.value));}}
  finally{reader.releaseLock();}
  return testa.toString()==='%PDF-'?new Uint8Array(Buffer.concat(chunks)):null;
 }catch{return null;}
}

export async function improntaPdfOriginaleK(testo:string,richiedi:typeof fetch=fetch):Promise<string|null>{const bytes=await leggiPdfOriginaleK(testo,richiedi);return bytes?createHash('sha256').update(bytes).digest('hex'):null;}
