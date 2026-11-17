export type EvasionePratica = {
 pratica_id: string; numero_pratica: number; targa: string | null; stato: 'da_evadere' | 'evaso' | 'da_verificare';
 revisione: number; nota: string; updated_at: string; stato_fatturazione: string; shopify_order_id: string | null; blocco_operatore: boolean;
};
export type VerificaOrdine = { id: string; pratica_id: string; numero_pratica: number; targa: string | null;
 evento_id: number | null; evento_at: string; messaggio: string; stato_commerciale: string; blocco_operatore: boolean; possibile_revoca: boolean;
 originale_messaggio_id?: string | null; blocco_classificazione_operatore?: boolean;
 prova_modificata?: boolean; collegamento_da_verificare?: boolean };
export function fonteVerificaOrdine(v: Pick<VerificaOrdine, 'evento_id' | 'originale_messaggio_id'>) {
 return [v.evento_id != null ? `Evento live ${v.evento_id}` : null,
  v.originale_messaggio_id ? `Messaggio originale ${v.originale_messaggio_id}` : null].filter(Boolean).join(' · ') || 'Fonte da verificare';
}
export type ShopifyCoda = { id: string; pratica_id: string | null; conflitto: boolean;
 dati: { ordine_id: string; numero: string; stato_evasione?: string; test: boolean; annullato: boolean; stato_pagamento: string } };
export function classificaCoda(shopify: ShopifyCoda[], pratiche: EvasionePratica[]) {
 const reali = shopify.filter(r => !r.dati.test && !r.dati.annullato && !['refunded','voided','expired'].includes(r.dati.stato_pagamento));
 // La fonte Shopify prevale anche per annullamenti: non riaprire il duplicato locale.
 const collegate = new Set(shopify.flatMap(r => r.pratica_id ? [r.pratica_id] : []));
 const ordini = new Set(shopify.map(r => r.dati.ordine_id));
 const locali = pratiche.filter(p => !collegate.has(p.pratica_id) && !ordini.has((p.shopify_order_id || '').replace('gid://shopify/Order/', '')));
 const shopifyAperti = reali.filter(r => !r.conflitto && ['da_evadere','parziale'].includes(r.dati.stato_evasione || ''));
 const shopifyDaVerificare = reali.filter(r => r.conflitto || !['da_evadere','parziale','evaso'].includes(r.dati.stato_evasione || ''));
 return { shopifyAperti, shopifyDaVerificare, shopifyEvasi: reali.filter(r => !r.conflitto && r.dati.stato_evasione === 'evaso'),
  praticheAperte: locali.filter(p => p.stato === 'da_evadere' && !p.shopify_order_id),
  praticheDaVerificare: locali.filter(p => p.stato === 'da_verificare' || !!p.shopify_order_id),
  praticheEvase: locali.filter(p => p.stato === 'evaso' && !p.shopify_order_id) };
}
export function numeroPratica(n: number) { return 'ABS-' + String(n).padStart(6,'0'); }
export function oraRoma(t: string) { return new Intl.DateTimeFormat('it-IT', { timeZone:'Europe/Rome', dateStyle:'short', timeStyle:'short' }).format(new Date(t)); }
