import 'server-only';
import {createHash} from 'node:crypto';
import {connessioneGlsDb} from './glsServer';
import {leggiMessaggiConversazioneKeplero} from './kepleroMessagesServer';
import {ErroreMessaggiKeplero} from './kepleroMessages';
import {normalizzaOriginaliK,leggiPdfOriginaleK,pdfOriginaleK} from './originaliKeplero';
import {elencoConversazioniK} from './conversazioniKeplero';
import {leggiOffertaDaPdf} from './offerte';

class ErroreRegistroK extends Error {constructor(readonly codice:string){super('Registro originali K non disponibile');}}
export async function rpcOriginaliK<T>(nome:string,dati:Record<string,unknown>={}):Promise<T>{
 const {url,headers}=connessioneGlsDb();
 const r=await fetch(`${url}/rest/v1/rpc/${nome}`,{method:'POST',headers,body:JSON.stringify(dati),cache:'no-store',signal:AbortSignal.timeout(20000)});
 if(!r.ok){const e=await r.json().catch(()=>null);throw new ErroreRegistroK(/^[A-Z0-9]{5}$/.test(e?.code||'')?e.code:`http_${r.status}`);}
 const body=await r.text();return (body?JSON.parse(body):null) as T;
}
export async function recuperaOriginaliK(){
 // Il lease copre anche l'elenco, impedendo due discovery concorrenti.
 const avvio=await rpcOriginaliK<{lease:string|null;scopri:boolean}>('avvia_lotto_originali_k');
 if(!avvio.lease)return {esito:'in_corso',controllate:0};
 const lease=avvio.lease;
 try{
  if(avvio.scopri){
   try{
    const liste=await Promise.all(['2aef20d3-5ef8-4c81-8f21-bd450f22960c','027160a9-3c91-490c-92f7-d0236aff8352'].map(id=>elencoConversazioniK(id,process.env.KEPLERO_API_KEY)));
    await rpcOriginaliK('registra_elenco_originali_k',{p_lease:lease,p_sessioni:liste.flat()});
   }catch(e){
    const codice=e instanceof Error&&/^elenco_[a-zA-Z0-9_]+$/.test(e.message)?e.message:'elenco_non_completato';
    await rpcOriginaliK('errore_elenco_originali_k',{p_lease:lease,p_errore:codice});
   }
  }
  const sessioni=await rpcOriginaliK<string[]>('seleziona_sessioni_originali_k',{p_lease:lease});
  const esiti=await Promise.all(sessioni.map(async sessione=>{
   let fase='lettura';
   try{
    const grezzi=await leggiMessaggiConversazioneKeplero(sessione);
    fase='normalizzazione';
    let messaggi;
    try{messaggi=normalizzaOriginaliK(sessione,grezzi);}catch(e){await rpcOriginaliK('conserva_snapshot_invalido_k',{p_lease:lease,p_sessione:sessione,p_snapshot:grezzi}).catch(()=>{});throw e;}
    fase='registro';
    await rpcOriginaliK('registra_originali_k',{p_lease:lease,p_sessione:sessione,p_messaggi:messaggi});
    fase='pdf_lettura';
    const documenti=await Promise.all(messaggi.filter(m=>m.targa_pdf).slice(-8).map(async m=>{
     const bytes=await leggiPdfOriginaleK(m.testo);
     if(!bytes)return null;
     m.sha256_pdf=createHash('sha256').update(bytes).digest('hex');
     try{return {m,contenuto:await leggiOffertaDaPdf(bytes,m.targa_pdf!)};}catch{return null;}
    }));
    fase='registro';
    // Prima conserviamo TUTTI i messaggi, poi elaboriamo i documenti. Un parser
    // o una regola fallita non può cancellare la prova originale.
    await rpcOriginaliK('registra_originali_k',{p_lease:lease,p_sessione:sessione,p_messaggi:messaggi});
    fase='pdf_registro';
    for(const d of documenti){if(!d)continue;
     try{await rpcOriginaliK('registra_pdf_originale_k',{p_lease:lease,p_sessione:sessione,p_messaggio_id:d.m.id,p_contenuto:d.contenuto,p_url:pdfOriginaleK(d.m.testo)!.url});}
     catch(e){
      // Un abbinamento rifiutato dalla regola non invalida i messaggi letti.
      // Il documento resta in verifica, senza aggirare la prova di invio.
      if(!(e instanceof ErroreRegistroK)||e.codice!=='P0001')throw e;
      const {url,headers}=connessioneGlsDb();
      const r=await fetch(`${url}/rest/v1/keplero_verifiche_originali?sessione=eq.${sessione}&messaggio_id=eq.${encodeURIComponent(d.m.id)}&esito=eq.da_verificare`,{method:'PATCH',headers,body:JSON.stringify({motivo:'Documento originale conservato: abbinamento o prova di invio respinti. Verificare conversazione e pratica prima di registrare il preventivo.'}),cache:'no-store',signal:AbortSignal.timeout(10000)});
      if(!r.ok)throw new ErroreRegistroK(`http_${r.status}`);
      console.warn('keplero_documento_da_verificare',{sessione,messaggio:d.m.id,codice:e.codice});
     }
    }
    fase='rivalutazione';
    await rpcOriginaliK('rivaluta_originali_k',{p_lease:lease,p_sessione:sessione});
    return {esito:'completato'};
   }catch(e){
    const codice=e instanceof ErroreMessaggiKeplero?e.codice:`${fase}_${e instanceof ErroreRegistroK?e.codice:'fallita'}`;
    console.warn('keplero_recupero_sessione',{sessione,fase,codice});
    await rpcOriginaliK('errore_originali_k',{p_lease:lease,p_sessione:sessione,p_errore:codice}).catch(()=>{});
    return {esito:'errore',codice};
   }
  }));
  return {esito:'completato',controllate:esiti.length,errori:esiti.filter(e=>e.esito==='errore').length};
 }finally{await rpcOriginaliK('termina_recupero_originali_k',{p_lease:lease});}
}
