import 'server-only';
import { createHash } from 'node:crypto';
import { connessioneGlsDb } from './glsServer';
import { clientFic } from './fattureInCloudServer';
import { clientiCompatibili, identitaFiscaleCompleta, queryClienteFic, urlPdfChat, fatturaCorrisponde, type IdentitaFic } from './ficAutomazioni';
import { leggiDocumentoAmministrativoPdf } from './documentiAmministrativi';
import type { OriginaleK } from './originaliKeplero';

export async function rpcFic<T>(nome: string, dati: Record<string,unknown> = {}): Promise<T> {
  const {url,headers}=connessioneGlsDb();
  const r=await fetch(`${url}/rest/v1/rpc/${nome}`,{method:'POST',headers,body:JSON.stringify(dati),cache:'no-store',signal:AbortSignal.timeout(20000)});
  if(!r.ok){await r.body?.cancel();throw new Error('Controllo amministrativo non completato');}
  const text=await r.text();return (text?JSON.parse(text):null) as T;
}
export async function verificaClientiOrdiniFic() {
  if(process.env.FIC_AUTOMAZIONI_ENABLED!=='true')return;
  const righe=await rpcFic<(IdentitaFic & {id:string})[]>('fic_ordini_da_controllare');
  for(const p of righe){
    try{
      const q=queryClienteFic(p);
      if(!q){await rpcFic('fic_registra_controllo_cliente',{p_pratica:p.id,p_clienti:[],p_esito:'identita_mancante'});continue;}
      const rows=await clientFic().cercaClienti(q), matches=clientiCompatibili(p,rows);
      // Gli identificativi fiscali sono necessari per concludere che si tratta di un nuovo cliente.
      const stato=matches.length===1?'riconosciuto':matches.length>1?'ambiguo':rows.length?'ambiguo':
        identitaFiscaleCompleta(p)?'nuovo':'identita_mancante';
      const campi=['id','name','vat_number','tax_code','address_street','address_postal_code','address_city','address_province','country','email','phone','certified_email','ei_code'];
      await rpcFic('fic_registra_controllo_cliente',{p_pratica:p.id,p_clienti:matches.slice(0,10).map(c=>Object.fromEntries(campi.map(k=>[k,c[k]??null]))),p_esito:stato});
    }catch{await rpcFic('fic_registra_controllo_cliente',{p_pratica:p.id,p_clienti:[],p_esito:'errore'}).catch(()=>{});}
  }
}
async function scaricaPdf(url:string) {
  const r=await fetch(url,{cache:'no-store',redirect:'error',signal:AbortSignal.timeout(10000)});
  if(!r.ok||Number(r.headers.get('content-length')||0)>3*1024*1024){await r.body?.cancel();throw new Error('PDF non disponibile');}
  const reader=r.body?.getReader();if(!reader)throw new Error('PDF assente');
  const parti:Uint8Array[]=[];let size=0;
  try{for(;;){const p=await reader.read();if(p.done)break;size+=p.value.length;if(size>3*1024*1024){await reader.cancel();throw new Error('PDF troppo grande');}parti.push(p.value);}}
  finally{reader.releaseLock();}
  return new Uint8Array(Buffer.concat(parti));
}
export async function verificaFattureChatFic() {
  if(process.env.FIC_AUTOMAZIONI_ENABLED!=='true')return;
  const candidati=await rpcFic<(OriginaleK & {sessione:string})[]>('fic_documenti_chat_da_controllare');
  for(const m of candidati){
    const sessione=m.sessione;
    const url=urlPdfChat(m);
    if(!url)continue; // La conferma di consegna può arrivare in seguito.
    let bytes: Uint8Array;
    try { bytes=await scaricaPdf(url); } catch { continue; } // Riprova gli errori temporanei di download.
    let pdf;
    try{
      pdf=await leggiDocumentoAmministrativoPdf(bytes,'',true);
      if(pdf.tipo!=='fattura'){await rpcFic('fic_esito_controllo_pdf',{p_sessione:sessione,p_messaggio:m.id,p_esito:'non_fattura'});continue;}
      m.sha256_pdf=createHash('sha256').update(bytes).digest('hex');
    }catch{
      await rpcFic('fic_esito_controllo_pdf',{p_sessione:sessione,p_messaggio:m.id,p_esito:'non_riconosciuto'});
      if(/fattura/i.test(decodeURIComponent(url)))await rpcFic('fic_segnala_fattura_chat',{p_sessione:sessione,p_messaggio:m.id});
      continue;
    }
    try{
      const r=await clientFic().cerca({tipo:'invoice',dal:pdf.data,al:pdf.data,cerca:''});
      const trovate=r.documenti.filter(d=>fatturaCorrisponde(pdf,d));
      if(!r.completo||trovate.length!==1)throw new Error('Fattura non univoca');
      await rpcFic('fic_registra_fattura_chat',{p_sessione:sessione,p_messaggio:m.id,p_pdf:{...pdf,sha256_pdf:m.sha256_pdf},p_fic:trovate[0]});
      await rpcFic('fic_esito_controllo_pdf',{p_sessione:sessione,p_messaggio:m.id,p_esito:'fatturata'});
    }catch{
      await rpcFic('fic_segnala_fattura_chat',{p_sessione:sessione,p_messaggio:m.id}).catch(()=>{});
    }
  }
}
