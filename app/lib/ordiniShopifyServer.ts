import 'server-only';
import { fetchTutteLePagine } from './supabaseRest';
import { connessioneGlsDb } from './glsServer';
import { rpcEmail } from './emailLogisticaServer';
import { valutaOrdineShopify, type OrdineShopify, type ValutazioneShopify } from './ordiniShopify';
import { unisciOrdini, type SnapshotApi } from './shopifyApi';

export type RigaOrdineShopify = { id: string; dati: OrdineShopify; valutazione: ValutazioneShopify; ricevuto_at: string; conflitto: boolean; pratica_id: string | null };
export type StatoOrdiniShopify = { ricevuti: number; pronti: number; attesa_pagamento: number; verifiche_iva: number; ultimo_evento_at: string | null };
export async function registraOrdineShopify(ordine: OrdineShopify) {
  return rpcEmail<{ esito: string; id: string }>('registra_ordine_shopify', { p_dati: ordine, p_valutazione: valutaOrdineShopify(ordine) });
}
export async function statoOrdiniShopify():Promise<StatoOrdiniShopify> {
 const righe=await leggiOrdiniShopify();
 return {ricevuti:righe.length,pronti:righe.filter(r=>!r.conflitto&&r.valutazione.pronto_ordine).length,
  attesa_pagamento:righe.filter(r=>r.valutazione.pagamento_richiesto&&r.dati.stato_pagamento!=='paid').length,
  verifiche_iva:righe.filter(r=>r.valutazione.verifica_iva).length,ultimo_evento_at:righe[0]?.ricevuto_at??null};
}
export async function leggiOrdiniShopify(soloAttivi = true): Promise<RigaOrdineShopify[]> {
  const { url, headers } = connessioneGlsDb();
  const [righe,api] = await Promise.all([
   fetchTutteLePagine<RigaOrdineShopify>(`${url}/rest/v1/ordini_shopify?select=id,dati,valutazione,ricevuto_at,conflitto,pratica_id&order=ricevuto_at.desc,id.asc`, { headers }),
   fetchTutteLePagine<SnapshotApi>(`${url}/rest/v1/ordini_shopify_api?select=ordine_id,dati,verificato_at&order=ordine_id.asc`, { headers }),
  ]);
  return unisciOrdini(righe,api).map(r => ({ ...r, valutazione: valutaOrdineShopify(r.dati) })).filter(r=>!soloAttivi||r.valutazione.attivo);
}
