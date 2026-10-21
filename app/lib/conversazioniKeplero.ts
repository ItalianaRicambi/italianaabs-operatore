/** Elenco documentato da Keplero Support il 21/10/2026. Leggiamo tutte le pagine:
 * le chat aperte precedono quelle chiuse, quindi la data non è un ordine globale. */
export type ConversazioneK={sessione:string;attivita:string;assistente:string};
const UUID=/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
export async function elencoConversazioniK(assistente:string,chiave:string|undefined,richiedi:typeof fetch=fetch):Promise<ConversazioneK[]>{
 if(!UUID.test(assistente)||!chiave?.trim())throw new Error('elenco_non_configurato');
 const signal=AbortSignal.timeout(25000),risultati=new Map<string,ConversazioneK>();
 for(let pagina=1;pagina<=200;pagina++){
  const r=await richiedi(`https://v2.api.keplero.ai/conversations/${assistente}?page=${pagina}&perPage=50&sort=desc`,{headers:{Authorization:`Bearer ${chiave.trim().replace(/^Bearer\s+/i,'')}`,Accept:'application/json'},redirect:'error',cache:'no-store',signal});
  if(!r.ok){await r.body?.cancel();throw new Error(`elenco_http_${r.status}`);}
  const text=await r.text();if(text.length>4*1024*1024)throw new Error('elenco_limite_superato');
  const body:unknown=JSON.parse(text);
  const o=body as Record<string,unknown>;
  const dati=Array.isArray(body)?body:o?.data??o?.conversations??o?.sessions;
  if(!Array.isArray(dati))throw new Error('elenco_schema_'+Object.keys(o||{}).join('_').slice(0,100));
  for(const v of dati){
   if(!v||typeof v!=='object'||!UUID.test(String(v.session_id)))throw new Error('elenco_sessione_non_valida');
   if(v.last_message_timestamp==null)continue;
   const t=String(v.last_message_timestamp).replace(' ','T').replace(/([+-]\d\d)$/,'$1:00');
   if(!/\d(?:Z|[+-]\d\d:\d\d)$/.test(t)||!Number.isFinite(Date.parse(t)))throw new Error('elenco_data_non_valida');
   risultati.set(v.session_id,{sessione:v.session_id,attivita:new Date(t).toISOString(),assistente});
  }
  const p=o?.pagination as {total?:number}|undefined;
  if(p?.total!==undefined&&(!Number.isSafeInteger(p.total)||p.total<0))throw new Error('elenco_paginazione_non_valida');
  if((p?.total!==undefined&&pagina*50>=p.total)||dati.length<50)return [...risultati.values()];
 }
 throw new Error('elenco_limite_superato');
}
