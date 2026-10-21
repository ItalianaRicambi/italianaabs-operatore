import 'server-only';
import {createHash} from 'node:crypto';
import {connessioneGlsDb} from './glsServer';
import {leggiMessaggiConversazioneKeplero} from './kepleroMessagesServer';
import {ErroreMessaggiKeplero} from './kepleroMessages';
import {normalizzaOriginaliK,leggiPdfOriginaleK,pdfOriginaleK} from './originaliKeplero';
import {elencoConversazioniK} from './conversazioniKeplero';
import {leggiOffertaDaPdf} from './offerte';

export async function rpcOriginaliK<T>(nome:string,dati:Record<string,unknown>={}):Promise<T>{
 const {url,headers}=connessioneGlsDb();
 const r=await fetch(`${url}/rest/v1/rpc/${nome}`,{method:'POST',headers,body:JSON.stringify(dati),cache:'no-store',signal:AbortSignal.timeout(20000)});
 if(!r.ok)throw new Error('Registro originali K non disponibile');
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
   try{
    const messaggi=normalizzaOriginaliK(sessione,await leggiMessaggiConversazioneKeplero(sessione));
    await rpcOriginaliK('registra_originali_k',{p_lease:lease,p_sessione:sessione,p_messaggi:messaggi});
    const documenti=await Promise.all(messaggi.filter(m=>m.targa_pdf).slice(-8).map(async m=>{
     const bytes=await leggiPdfOriginaleK(m.testo);
     if(!bytes)return null;
     m.sha256_pdf=createHash('sha256').update(bytes).digest('hex');
     try{return {m,contenuto:await leggiOffertaDaPdf(bytes,m.targa_pdf!)};}catch{return null;}
    }));
    // Prima conserviamo TUTTI i messaggi, poi elaboriamo i documenti. Un parser
    // o una regola fallita non può cancellare la prova originale.
    await rpcOriginaliK('registra_originali_k',{p_lease:lease,p_sessione:sessione,p_messaggi:messaggi});
    for(const d of documenti){if(!d)continue;
     await rpcOriginaliK('registra_pdf_originale_k',{p_lease:lease,p_sessione:sessione,p_messaggio_id:d.m.id,p_contenuto:d.contenuto,p_url:pdfOriginaleK(d.m.testo)!.url});
    }
    await rpcOriginaliK('rivaluta_originali_k',{p_lease:lease,p_sessione:sessione});
    return {esito:'completato'};
   }catch(e){
    const codice=e instanceof ErroreMessaggiKeplero?e.codice:'lettura_non_completata';
    await rpcOriginaliK('errore_originali_k',{p_lease:lease,p_sessione:sessione,p_errore:codice}).catch(()=>{});
    return {esito:'errore',codice};
   }
  }));
  return {esito:'completato',controllate:esiti.length,errori:esiti.filter(e=>e.esito==='errore').length};
 }finally{await rpcOriginaliK('termina_recupero_originali_k',{p_lease:lease});}
}
