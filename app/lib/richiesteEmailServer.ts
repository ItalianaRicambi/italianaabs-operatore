import 'server-only';
import { NextRequest } from 'next/server';
import { POST as sincronizzaLive } from '../api/keplero/live/route';
import { rpcEmail } from './emailLogisticaServer';
import { connessioneGlsDb } from './glsServer';
import { esclusioneEmail, payloadEmail, praticaDaEsitoEmail, type EmailOriginale } from './richiesteEmail';

export type RichiestaEmail = {id:string;sender:string;subject:string;content:string;conversation_id:string;fingerprint:string;mailbox:string;stato:string;motivo:string|null;pratica_id:string|null;created_at:string;updated_at:string;consegne:number;token?:string|null;allegati_da_verificare:boolean};
export async function leggiRichiesteEmail() {
 const {url,headers}=connessioneGlsDb();
 const r=await fetch(`${url}/rest/v1/richieste_email?select=id,sender,subject,content,conversation_id,fingerprint,mailbox,stato,motivo,pratica_id,created_at,updated_at,consegne,allegati_da_verificare&order=created_at.desc&limit=200`,{headers,cache:'no-store'});
 if(!r.ok) throw new Error('Registro email non disponibile');
 return r.json() as Promise<RichiestaEmail[]>;
}
export async function processaRichiestaEmail(e:EmailOriginale) {
 const claim=await rpcEmail<RichiestaEmail>('registra_richiesta_email',{p_dati:e});
 if(!claim.token) return {ok:!['errore','in_elaborazione'].includes(claim.stato),esito:claim.stato,id:claim.id,pratica_id:claim.pratica_id};
 const token=claim.token;
 try {
  const esclusione=esclusioneEmail(e), p=payloadEmail(e);
  let stato='da_classificare', motivo='Email ricevuta: classificazione da parte dell’operatore.', pratica:string|null=null;
  if(esclusione){stato='esclusa';motivo=esclusione;}
  else if(p.operativo){
   const secret=process.env.KEPLERO_WEBHOOK_SECRET;
   if(!secret) throw new Error('Collegamento non configurato');
   const response=await sincronizzaLive(new NextRequest('https://italianaabs-operatore.vercel.app/api/keplero/live',{method:'POST',headers:{'x-keplero-secret':secret,'Content-Type':'application/json'},body:JSON.stringify(p.body)}));
   const result=await response.json();
   if(!response.ok || result.ok!==true) throw new Error('Sincronizzazione non completata');
   pratica=praticaDaEsitoEmail(result);
   stato=pratica?'registrata':'da_classificare';
   motivo=pratica?'Richiesta collegata alla pratica.':'Richiesta registrata: abbinamento alla pratica da verificare.';
   if(p.allegatiIndicati && p.body.email_allegati_da_verificare) motivo+=' Allegati indicati ma non trasmessi: aprire l’email originale in Keplero.';
  }
  const salvata=await rpcEmail<boolean>('esito_richiesta_email',{p_id:claim.id,p_token:token,p_stato:stato,p_pratica_id:pratica,p_motivo:motivo,p_allegati_da_verificare:p.body.email_allegati_da_verificare});
  if(!salvata) throw new Error('Esito non registrato');
  return {ok:true,esito:stato,id:claim.id,pratica_id:pratica};
 } catch {
  await rpcEmail('esito_richiesta_email',{p_id:claim.id,p_token:token,p_stato:'errore',p_pratica_id:null,p_motivo:'Elaborazione non completata. Il messaggio originale è conservato; verificare e riprovare dalla sezione Richieste email.',p_allegati_da_verificare:false});
  return {ok:false,esito:'errore',id:claim.id};
 }
}
