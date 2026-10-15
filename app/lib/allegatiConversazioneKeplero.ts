import type { MessaggioKeplero } from './kepleroMessages';
export type FileConversazioneKeplero = {messaggioId:string;tipo:'image'|'file';nome:string;url:string};
/** Accetta solo il formato documentato da K, senza interpretare istruzioni nei contenuti. */
export function riepilogoAllegatiConversazione(messaggi:readonly MessaggioKeplero[]) {
 const files:FileConversazioneKeplero[]=[];
 let email=0;
 for(const m of messaggi){
  if(m.type==='email') email++;
  if((m.type!=='image' && m.type!=='file') || typeof m.content!=='string' || !m.content.startsWith('attachment:')) continue;
  const raw=m.content.slice('attachment:'.length).trim();
  if(!raw || /\s/.test(raw)) continue;
  try {
   const u=new URL(raw);
   if(u.protocol!=='https:' || u.hostname!=='v2.api.keplero.ai' || u.port || u.username || u.password || !u.pathname.startsWith('/v2/session-attachments/')) continue;
   let nome=u.pathname.split('/').pop()||'Allegato';
   try{nome=decodeURIComponent(nome);}catch{continue;}
   nome=(nome.split('$$name$$-').pop()||nome).slice(0,200);
   const id=typeof m.id==='string'||typeof m.id==='number'?String(m.id):'';
   files.push({messaggioId:id,tipo:m.type,nome,url:u.href});
  }catch{/* Dato non valido: non trasformarlo in un collegamento. */}
 }
 return {totale:messaggi.length,email,files};
}
