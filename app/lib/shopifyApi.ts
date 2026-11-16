import { normalizzaOrdineShopify, valutaOrdineShopify, type OrdineShopify } from './ordiniShopify.ts';
import type { RigaOrdineShopify } from './ordiniShopifyServer';

export const SHOPIFY_API_VERSION = '2026-10';
// Aliases keep the same normalization rules as signed webhooks. No mutation.
export const QUERY_ORDINI = `query RiconciliaOrdini($after: String, $query: String!) {
 orders(first: 10, after: $after, query: $query, sortKey: UPDATED_AT) {
  pageInfo { hasNextPage endCursor }
  nodes {
   admin_graphql_api_id: id name updated_at: updatedAt test cancelled_at: cancelledAt
   financial_status: displayFinancialStatus fulfillment_status: displayFulfillmentStatus
   email currency: currencyCode tax_exempt: taxExempt
   currentTotalPriceSet { shopMoney { amount } }
   currentTotalTaxSet { shopMoney { amount } }
   note_attributes: customAttributes { name: key value }
   billing_address: billingAddress { name company address1 address2 city zip province_code: provinceCode country_code: countryCodeV2 }
   shipping_address: shippingAddress { name company address1 address2 city zip province_code: provinceCode country_code: countryCodeV2 }
   line_items: lineItems(first: 50) {
    pageInfo { hasNextPage endCursor }
    nodes { title variant_title: variantTitle quantity properties: customAttributes { name: key value } }
   }
  }
 }
}`;
export type Pagina<T> = { nodes: T[]; pageInfo: { hasNextPage: boolean; endCursor: string | null } };
export type OrdineApi = Record<string, unknown> & {
 admin_graphql_api_id: string; financial_status: string | null; fulfillment_status: string;
 currentTotalPriceSet: { shopMoney: { amount: string } }; currentTotalTaxSet: { shopMoney: { amount: string } };
 line_items: Pagina<Record<string, unknown>>;
};
export function normalizzaApi(o: OrdineApi): OrdineShopify {
 // A truncated order is never recorded as complete. Fail visibly rather than silently lose lines.
 if (!o.line_items || o.line_items.pageInfo.hasNextPage) throw new Error('ORDINE_TROPPE_RIGHE');
 const fulfillment = ({ FULFILLED:'fulfilled', PARTIALLY_FULFILLED:'partial', UNFULFILLED:'unfulfilled' } as Record<string,string>)[o.fulfillment_status] ?? 'unknown';
 return normalizzaOrdineShopify({ ...o, financial_status:o.financial_status?.toLowerCase(), fulfillment_status:fulfillment,
  current_total_price:o.currentTotalPriceSet?.shopMoney.amount, current_total_tax:o.currentTotalTaxSet?.shopMoney.amount,
  line_items:o.line_items.nodes });
}
export type SnapshotApi = { ordine_id: string; dati: OrdineShopify; verificato_at: string };
export function unisciOrdini(webhooks: RigaOrdineShopify[], api: SnapshotApi[]): RigaOrdineShopify[] {
 const result = new Map(webhooks.map(r=>[r.dati.ordine_id,r]));
 for (const a of api) {
  const w = result.get(a.ordine_id);
  if (w && Date.parse(w.dati.aggiornato_shopify_at)>Date.parse(a.dati.aggiornato_shopify_at)) {
   if (a.dati.annullato && !w.dati.annullato) {
    const dati={...w.dati,annullato:true};
    result.set(a.ordine_id,{...w,dati,conflitto:true,valutazione:valutaOrdineShopify(dati)});
   }
   continue;
  }
  // Never undo cancellation; never clear a conflict or an operator link.
  const dati = { ...a.dati, annullato: a.dati.annullato || w?.dati.annullato === true };
  const stessaVersione = w && Date.parse(w.dati.aggiornato_shopify_at)===Date.parse(dati.aggiornato_shopify_at);
  const discordante = stessaVersione && ['totale','iva','valuta','stato_pagamento','test'].some(k=>w.dati[k as keyof OrdineShopify]!==dati[k as keyof OrdineShopify]);
  result.set(a.ordine_id, { id:w?.id ?? 'api-'+a.ordine_id, pratica_id:w?.pratica_id ?? null,
   conflitto:!!w?.conflitto || !!discordante, dati, valutazione:valutaOrdineShopify(dati), ricevuto_at:a.verificato_at });
 }
 return [...result.values()].sort((a,b)=>b.ricevuto_at.localeCompare(a.ricevuto_at));
}
export type StatoSync = { ultimo_avvio_at: string | null; ultimo_successo_at: string | null; errore: string | null; ordini_letti: number; finestra_da: string | null };
export function problemaSync(s: StatoSync | null, now=Date.now()): string | null {
 if (!s) return 'Stato del controllo Shopify non disponibile.';
 if (s.errore) return 'Controllo Shopify in errore: '+s.errore;
 if (!s.ultimo_successo_at) return 'Lettura API Shopify non ancora collaudata.';
 if (!Number.isFinite(Date.parse(s.ultimo_successo_at)) || now-Date.parse(s.ultimo_successo_at)>15*60_000) return 'Controllo Shopify fermo o in ritardo: ultimo completamento oltre 15 minuti fa.';
 return null;
}
