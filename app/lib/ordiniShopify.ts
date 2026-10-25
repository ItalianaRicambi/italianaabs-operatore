import { createHmac, timingSafeEqual } from 'node:crypto';

export const NEGOZIO_SHOPIFY = 'j4mqgv-am.myshopify.com';
const UE = new Set('AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK'.split(' '));
type Oggetto = Record<string, unknown>;
export type IndirizzoShopify = { nome: string; azienda: string; via: string; citta: string; cap: string; provincia: string; paese: string | null };
export type ServizioShopify = 'PS' | 'PSMI' | 'RE' | 'RI' | 'da_verificare';
export type OrdineShopify = {
  shop: string; ordine_id: string; numero: string; aggiornato_shopify_at: string;
  test: boolean; annullato: boolean; stato_pagamento: string;
  cliente: string; email: string; fatturazione: IndirizzoShopify; spedizione: IndirizzoShopify;
  partita_iva_dichiarata: string | null; partita_iva_discordante: boolean; tipo_cliente: 'azienda_dichiarata' | 'non_dichiarato';
  totale: number; iva: number | null; valuta: string; esente_shopify: boolean | null;
  servizi: ServizioShopify[]; articoli: { titolo: string; variante: string; quantita: number }[];
};
export type ValutazioneShopify = {
  attivo: boolean; pronto_ordine: boolean; pagamento_richiesto: boolean;
  stato_iva: 'iva_applicata' | 'esenzione_shopify' | 'da_verificare';
  verifica_iva: boolean; messaggio_iva: string; motivazione_ordine: string;
};
function oggetto(v: unknown): Oggetto { return v && typeof v === 'object' && !Array.isArray(v) ? v as Oggetto : {}; }
function testo(v: unknown, max = 500) { return typeof v === 'string' ? v.trim().slice(0, max) : ''; }
function paese(v: unknown) { const p = testo(v).toUpperCase(); return /^[A-Z]{2}$/.test(p) ? p : null; }
function importo(v: unknown): number | null {
  if (typeof v !== 'string' || !/^\d{1,12}(?:\.\d{1,2})?$/.test(v)) return null;
  const centesimi = Number(v.split('.')[0]) * 100 + Number((v.split('.')[1] || '').padEnd(2, '0'));
  return Number.isSafeInteger(centesimi) ? centesimi : null;
}
function indirizzo(v: unknown): IndirizzoShopify {
  const a = oggetto(v);
  return { nome: testo(a.name) || [testo(a.first_name), testo(a.last_name)].filter(Boolean).join(' '), azienda: testo(a.company),
    via: [testo(a.address1), testo(a.address2)].filter(Boolean).join(', '), citta: testo(a.city), cap: testo(a.zip),
    provincia: testo(a.province_code), paese: paese(a.country_code) };
}
export function firmaShopifyValida(body: Uint8Array, firma: string | null, segreto: string | undefined) {
  if (!segreto || segreto.length < 32 || !firma || !/^[A-Za-z0-9+/]{43}=$/.test(firma)) return false;
  const ricevuta = Buffer.from(firma, 'base64'), attesa = createHmac('sha256', segreto).update(body).digest();
  return ricevuta.length === attesa.length && timingSafeEqual(ricevuta, attesa);
}
export function servizioShopify(variante: unknown): ServizioShopify {
  const v = testo(variante).toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[\s–—_-]+/g, ' ').trim();
  if (v === 'psmi' || /^programma scambio made in italy\b/.test(v)) return 'PSMI';
  if (v === 'ps' || /^programma scambio\b/.test(v)) return 'PS';
  if (v === 're' || /^riparazione elettronica\b/.test(v)) return 'RE';
  if (v === 'ri' || /^riparazione idraulica\b/.test(v)) return 'RI';
  return 'da_verificare';
}
/** Solo dopo la verifica della firma: non usare questo adattatore su email o testo del bot. */
export function normalizzaOrdineShopify(value: unknown): OrdineShopify {
  const v = oggetto(value);
  const id = testo(v.admin_graphql_api_id).match(/^gid:\/\/shopify\/Order\/(\d+)$/)?.[1]
    || (typeof v.id === 'number' && Number.isSafeInteger(v.id) && v.id > 0 ? String(v.id) : typeof v.id === 'string' && /^\d{1,20}$/.test(v.id) ? v.id : '');
  const aggiornato = testo(v.updated_at), data = Date.parse(aggiornato);
  if (!id || !testo(v.name) || !/^\d{4}-\d\d-\d\dT/.test(aggiornato) || !Number.isFinite(data)) throw new Error('Ordine incompleto');
  if (typeof v.test !== 'boolean' || !Array.isArray(v.line_items) || v.line_items.length > 250 || !v.line_items.length) throw new Error('Righe ordine mancanti');
  if (!['pending','authorized','partially_paid','paid','partially_refunded','refunded','voided','expired'].includes(testo(v.financial_status))) throw new Error('Stato pagamento non valido');
  const totale = importo(v.current_total_price ?? v.total_price), iva = importo(v.current_total_tax ?? v.total_tax);
  if (totale === null || !/^[A-Z]{3}$/.test(testo(v.currency))) throw new Error('Importi ordine non validi');
  if (v.cancelled_at !== null && v.cancelled_at !== undefined && (typeof v.cancelled_at !== 'string' || !Number.isFinite(Date.parse(v.cancelled_at)))) throw new Error('Annullamento non valido');
  const articoli = v.line_items.map(item => {
    const r = oggetto(item);
    if (!Number.isSafeInteger(r.quantity) || (r.quantity as number) <= 0 || !testo(r.title)) throw new Error('Articolo non valido');
    return { titolo: testo(r.title), variante: testo(r.variant_title), quantita: r.quantity as number };
  });
  const fatturazione = indirizzo(v.billing_address), spedizione = indirizzo(v.shipping_address);
  const attributi = Array.isArray(v.note_attributes) ? v.note_attributes.map(oggetto) : [];
  const partiteIva = [...new Set(attributi.filter(a => /^(?:partita\s*iva|p\.?\s*iva|vat(?:\s*(?:number|id))?)$/i.test(testo(a.name)))
    .map(a => testo(a.value, 40).toUpperCase().replace(/\s/g, '')).filter(Boolean))];
  const partitaIva = partiteIva.length === 1 ? partiteIva[0] : null;
  return { shop: NEGOZIO_SHOPIFY, ordine_id: id, numero: testo(v.name, 100), aggiornato_shopify_at: new Date(data).toISOString(),
    test: v.test, annullato: !!v.cancelled_at, stato_pagamento: testo(v.financial_status),
    cliente: fatturazione.azienda || fatturazione.nome || spedizione.nome || 'Cliente da verificare', email: testo(v.email || v.contact_email, 254),
    fatturazione, spedizione, partita_iva_dichiarata: partitaIva, partita_iva_discordante: partiteIva.length > 1,
    tipo_cliente: fatturazione.azienda || partiteIva.length ? 'azienda_dichiarata' : 'non_dichiarato',
    totale, iva, valuta: testo(v.currency), esente_shopify: typeof v.tax_exempt === 'boolean' ? v.tax_exempt : null,
    servizi: [...new Set(articoli.map(r => servizioShopify(r.variante)))], articoli };
}
/** Esito dell'ordine, non prova VIES: Shopify non espone qui il motivo del controllo fallito. */
export function valutaOrdineShopify(o: OrdineShopify): ValutazioneShopify {
  const attivo = !o.test && !o.annullato && !['refunded','voided','expired'].includes(o.stato_pagamento);
  const pagamentoRichiesto = o.servizi.some(s => s === 'PS' || s === 'PSMI');
  const servizioIncerto = o.servizi.includes('da_verificare');
  const pronto = attivo && !servizioIncerto && o.stato_pagamento !== 'partially_refunded' && (!pagamentoRichiesto || o.stato_pagamento === 'paid');
  let stato: ValutazioneShopify['stato_iva'] = 'da_verificare', messaggio = 'Dati IVA incompleti: aprire l’ordine Shopify prima di fatturare.', verifica = true;
  const estero = !!o.spedizione.paese && o.spedizione.paese !== 'IT';
  if (o.iva !== null && o.esente_shopify !== null && o.spedizione.paese) {
    if (o.esente_shopify && o.iva === 0) {
      stato = 'esenzione_shopify';
      messaggio = 'IVA non addebitata da Shopify: verificare Partita IVA, intestazione e riferimento fiscale prima di fatturare. L’esito VIES del checkout non è trasmesso in questo evento.';
    } else if (!o.esente_shopify && o.iva > 0) {
      stato = 'iva_applicata'; verifica = estero && o.tipo_cliente === 'azienda_dichiarata';
      messaggio = verifica
        ? 'IVA addebitata a un’azienda estera: controllare Partita IVA e condizioni dell’ordine. Questo dato non dimostra che VIES sia fallito.'
        : 'IVA addebitata da Shopify. Nessuna esenzione dedotta dall’indirizzo estero.';
    } else {
      messaggio = o.esente_shopify && o.iva > 0 ? 'Dati fiscali discordanti: esenzione indicata ma IVA maggiore di zero. Verificare l’ordine.'
        : 'IVA pari a zero senza esenzione confermata da Shopify: verificare il trattamento fiscale.';
    }
    if (estero && !UE.has(o.spedizione.paese)) { verifica = true; messaggio += ' Destinazione fuori dal servizio UE standard: verifica commerciale richiesta.'; }
  }
  if (o.partita_iva_discordante) { verifica = true; messaggio += ' Più Partite IVA discordanti negli attributi ordine: controllare l’intestatario.'; }
  if (!attivo) { verifica = false; messaggio = 'Ordine di prova, annullato o chiuso: escluso dalla coda operativa.'; }
  return { attivo, pronto_ordine: pronto, pagamento_richiesto: pagamentoRichiesto, stato_iva: stato,
    verifica_iva: verifica, messaggio_iva: messaggio,
    motivazione_ordine: !attivo ? 'Ordine escluso dalla coda operativa.' : servizioIncerto ? 'Soluzione da verificare prima della stesura dell’ordine.'
      : o.stato_pagamento === 'partially_refunded' ? 'Rimborso parziale: verificare l’ordine.'
        : pagamentoRichiesto && o.stato_pagamento !== 'paid' ? 'PS/PSMI: attendere la conferma del pagamento completo da Shopify.'
          : pagamentoRichiesto ? 'Pagamento completo confermato da Shopify: l’operatore può preparare l’ordine.'
            : 'RE/RI: l’operatore può preparare l’ordine; il pagamento può avvenire a fine lavori.' };
}
