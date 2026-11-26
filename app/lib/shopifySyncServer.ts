import 'server-only';
import type { OrdineTracking } from './trackingWhatsApp';
import { NEGOZIO_SHOPIFY } from './ordiniShopify';
import { QUERY_ORDINI, SHOPIFY_API_VERSION, normalizzaApi, type OrdineApi, type Pagina, type StatoSync } from './shopifyApi';
import { connessioneGlsDb } from './glsServer';

class ErroreSync extends Error {}
let token: { valore:string; scade:number } | undefined;
async function accessToken(): Promise<string> {
 if (token && token.scade>Date.now()+60_000) return token.valore;
 const id=process.env.SHOPIFY_CLIENT_ID, secret=process.env.SHOPIFY_CLIENT_SECRET;
 if (!id || !secret) throw new ErroreSync('Credenziali Shopify mancanti');
 const r=await fetch('https://'+NEGOZIO_SHOPIFY+'/admin/oauth/access_token',{method:'POST',redirect:'error',cache:'no-store',
  headers:{'Content-Type':'application/x-www-form-urlencoded'},signal:AbortSignal.timeout(15_000),
  body:new URLSearchParams({grant_type:'client_credentials',client_id:id,client_secret:secret})});
 if (!r.ok) throw new ErroreSync('Autenticazione Shopify non riuscita (HTTP '+r.status+')');
 const data=await r.json();
 const scopes=typeof data.scope==='string'?data.scope.split(',').map((s:string)=>s.trim()).filter(Boolean):[];
 if (scopes.length!==1 || scopes[0]!=='read_orders') throw new ErroreSync('Permessi Shopify diversi dalla sola lettura ordini autorizzata');
 if (typeof data.access_token!=='string' || !data.access_token || !Number.isFinite(data.expires_in) || data.expires_in<120) throw new ErroreSync('Risposta autenticazione non valida');
 token={valore:data.access_token,scade:Date.now()+data.expires_in*1000};
 return token.valore;
}
async function rpc<T>(name:string, body:Record<string,unknown>={}):Promise<T> {
 const {url,headers}=connessioneGlsDb();
 const r=await fetch(url+'/rest/v1/rpc/'+name,{method:'POST',headers,body:JSON.stringify(body),cache:'no-store',signal:AbortSignal.timeout(12_000)});
 if (!r.ok) throw new ErroreSync('Registro sincronizzazione non disponibile (HTTP '+r.status+')');
 return r.json();
}
export async function leggiStatoSync():Promise<StatoSync|null> {
 return rpc<StatoSync>('stato_sync_shopify');
}
export async function sincronizzaShopify() {
 const lease=await rpc<string|null>('inizia_sync_shopify');
 if (!lease) return {ok:true,esito:'gia_in_corso'};
 let n=0;
 const iniziato=Date.now(), da=new Date(iniziato-60*86400_000).toISOString();
 try {
  const bearer=await accessToken();
  let after:string|null=null;
  const cursori=new Set<string>();
  do {
   if (Date.now()-iniziato>200_000 || n>=10_000) throw new ErroreSync('Scansione incompleta: limite operativo raggiunto');
   const r=await fetch('https://'+NEGOZIO_SHOPIFY+'/admin/api/'+SHOPIFY_API_VERSION+'/graphql.json',{
    method:'POST',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(20_000),
    headers:{'Content-Type':'application/json','X-Shopify-Access-Token':bearer},
    body:JSON.stringify({query:QUERY_ORDINI,variables:{after,query:"created_at:>='"+da+"'"}})});
   if (!r.ok) { if(r.status===401) token=undefined; throw new ErroreSync('Lettura Shopify non riuscita (HTTP '+r.status+')'); }
   const payload=await r.json();
   if (payload.errors?.length) throw new ErroreSync('Shopify ha rifiutato la lettura: verificare permessi, limiti API e campi richiesti');
   const pagina=payload.data?.orders as Pagina<OrdineApi> | undefined;
   if (!pagina || !Array.isArray(pagina.nodes) || typeof pagina.pageInfo?.hasNextPage!=='boolean') throw new ErroreSync('Risposta ordini incompleta');
   for(const ordine of pagina.nodes) {
    if (ordine.line_items?.pageInfo.hasNextPage) throw new ErroreSync('Ordine con oltre 50 righe: verifica manuale richiesta, scansione incompleta');
    const dati=normalizzaApi(ordine);
    await rpc('registra_snapshot_shopify',{p_token:lease,p_dati:dati});
    n++;
   }
   if (!pagina.pageInfo.hasNextPage) break;
   after=pagina.pageInfo.endCursor;
   if(!after || cursori.has(after)) throw new ErroreSync('Paginazione Shopify incompleta');
   cursori.add(after);
  } while(true);
  await rpc('termina_sync_shopify',{p_token:lease,p_errore:null,p_ordini:n,p_da:da});
  return {ok:true,esito:'completato',ordini:n};
 } catch(error) {
  // Never persist upstream bodies, credentials, customer data, or arbitrary exception messages.
  const motivo=error instanceof ErroreSync?error.message:'Scansione non completata: errore di rete o dati ordine non validi';
  await rpc('termina_sync_shopify',{p_token:lease,p_errore:motivo,p_ordini:n,p_da:da});
  return {ok:false,errore:motivo};
 }
}

export async function leggiTrackingOrdineShopify(id: string): Promise<OrdineTracking | null> {
 if (!/^\d{1,20}$/.test(id)) throw new Error('Identificativo ordine non valido');
 const bearer=await accessToken();
 const response=await fetch('https://'+NEGOZIO_SHOPIFY+'/admin/api/'+SHOPIFY_API_VERSION+'/graphql.json',{
  method:'POST',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(8000),
  headers:{'Content-Type':'application/json','X-Shopify-Access-Token':bearer},
  body:JSON.stringify({query:'query TrackingOrdine($id: ID!) { order(id: $id) { id name test cancelledAt shippingAddress { phone } fulfillments(first:100) { status trackingInfo { number url } } } }',
   variables:{id:'gid://shopify/Order/'+id}})});
 if (!response.ok) throw new Error('Tracking Shopify non disponibile');
 const payload=await response.json();
 if (payload.errors?.length || !payload.data) throw new Error('Lettura tracking Shopify incompleta');
 return payload.data.order;
}
