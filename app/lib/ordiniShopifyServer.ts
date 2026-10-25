import 'server-only';
import { connessioneGlsDb } from './glsServer';
import { rpcEmail } from './emailLogisticaServer';
import { valutaOrdineShopify, type OrdineShopify, type ValutazioneShopify } from './ordiniShopify';

export type RigaOrdineShopify = { id: string; dati: OrdineShopify; valutazione: ValutazioneShopify; ricevuto_at: string; conflitto: boolean; pratica_id: string | null };
export type StatoOrdiniShopify = { ricevuti: number; pronti: number; attesa_pagamento: number; verifiche_iva: number; ultimo_evento_at: string | null };
export async function registraOrdineShopify(ordine: OrdineShopify) {
  return rpcEmail<{ esito: string; id: string }>('registra_ordine_shopify', { p_dati: ordine, p_valutazione: valutaOrdineShopify(ordine) });
}
export async function statoOrdiniShopify() { return rpcEmail<StatoOrdiniShopify>('stato_ordini_shopify'); }
export async function leggiOrdiniShopify(): Promise<RigaOrdineShopify[]> {
  const { url, headers } = connessioneGlsDb();
  const response = await fetch(`${url}/rest/v1/ordini_shopify?select=id,dati,valutazione,ricevuto_at,conflitto,pratica_id&attivo=eq.true&order=ricevuto_at.desc&limit=200`, { headers, cache: 'no-store', signal: AbortSignal.timeout(10000) });
  if (!response.ok) throw new Error('Registro ordini Shopify non disponibile');
  return response.json();
}
