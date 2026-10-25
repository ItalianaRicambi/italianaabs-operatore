import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { firmaShopifyValida, normalizzaOrdineShopify, servizioShopify, valutaOrdineShopify } from './ordiniShopify.ts';

const originale = {
  id: 17911850598749, name: '#1003', updated_at: '2026-10-25T21:00:00Z', test: false, cancelled_at: null,
  financial_status: 'paid', current_total_price: '447.00', current_total_tax: '80.61', currency: 'EUR', tax_exempt: false,
  billing_address: { name: 'Mario Rossi', company: '', address1: 'Via A 1', city: 'Milano', zip: '20121', country_code: 'IT' },
  shipping_address: { name: 'Officina', address1: 'Via B 2', city: 'Oleggio', zip: '28047', country_code: 'IT' },
  line_items: [{ title: 'Centralina ABS', variant_title: 'Programma Scambio', quantity: 1 }],
};
test('la firma protegge i byte originali e rifiuta segreti mancanti e firme malformate', () => {
  const secret = 's'.repeat(32), body = Buffer.from(JSON.stringify(originale)), signature = createHmac('sha256', secret).update(body).digest('base64');
  assert.equal(firmaShopifyValida(body, signature, secret), true);
  assert.equal(firmaShopifyValida(Buffer.concat([body, Buffer.from(' ')]), signature, secret), false);
  for (const s of [null, '', signature + 'x', 'a'.repeat(44)]) assert.equal(firmaShopifyValida(body, s, secret), false);
  assert.equal(firmaShopifyValida(body, signature, undefined), false);
});
test('fatturazione e spedizione restano separate; importi espressi in centesimi', () => {
  const o = normalizzaOrdineShopify(originale);
  assert.equal(o.fatturazione.citta, 'Milano'); assert.equal(o.spedizione.citta, 'Oleggio');
  assert.equal(o.totale, 44700); assert.equal(o.iva, 8061); assert.equal(o.tipo_cliente, 'non_dichiarato');
});
test('importi invalidi e dati incompleti non diventano ordini pagati o esenti', () => {
  for (const price of ['', 'NaN', '-1', '447 euro', '1e2', '1.001']) assert.throws(() => normalizzaOrdineShopify({ ...originale, current_total_price: price }));
  assert.throws(() => normalizzaOrdineShopify({ ...originale, id: Number.MAX_SAFE_INTEGER + 1 }));
  assert.throws(() => normalizzaOrdineShopify({ ...originale, test: undefined }));
  assert.throws(() => normalizzaOrdineShopify({ ...originale, financial_status: 'Visa pagato' }));
  assert.throws(() => normalizzaOrdineShopify({ ...originale, line_items: [] }));
});
test('esenzione solo da flag fiscale dell’ordine e IVA zero, mai dal paese o dal profilo cliente', () => {
  const o = normalizzaOrdineShopify({ ...originale, shipping_address: { country_code: 'DE' }, current_total_tax: '0.00', tax_exempt: false, customer: { tax_exempt: true, tax_exemptions: ['EU_REVERSE_CHARGE_EXEMPTION_RULE'] } });
  const v = valutaOrdineShopify(o); assert.equal(v.stato_iva, 'da_verificare'); assert.equal(v.verifica_iva, true);
  const esente = valutaOrdineShopify({ ...o, esente_shopify: true });
  assert.equal(esente.stato_iva, 'esenzione_shopify'); assert.equal(esente.verifica_iva, true); assert.match(esente.messaggio_iva, /VIES.*non è trasmesso/);
});
test('IVA addebitata ad azienda estera genera controllo senza inventare un fallimento VIES', () => {
  const o = normalizzaOrdineShopify({ ...originale, billing_address: { country_code: 'DE', company: 'Officina GmbH' }, shipping_address: { country_code: 'DE' } });
  const v = valutaOrdineShopify(o); assert.equal(v.stato_iva, 'iva_applicata'); assert.equal(v.verifica_iva, true); assert.match(v.messaggio_iva, /non dimostra che VIES sia fallito/);
});
test('cliente senza azienda non viene qualificato come privato verificato né diventa esente', () => {
  const o = normalizzaOrdineShopify({ ...originale, shipping_address: { country_code: 'FR' } });
  assert.equal(o.tipo_cliente, 'non_dichiarato'); assert.equal(valutaOrdineShopify(o).stato_iva, 'iva_applicata');
});
test('dati IVA mancanti e discordanti rimangono da verificare', () => {
  const o = normalizzaOrdineShopify(originale);
  for (const variante of [{ iva: null }, { esente_shopify: null }, { esente_shopify: true, iva: 100 }, { iva: 0 }]) {
    assert.equal(valutaOrdineShopify({ ...o, ...variante }).stato_iva, 'da_verificare');
  }
});
test('la Partita IVA dichiarata è conservata senza fingere una validazione; valori discordanti non sono scelti arbitrariamente', () => {
  const a = normalizzaOrdineShopify({ ...originale, note_attributes: [{ name: 'Partita IVA', value: 'DE 123456789' }] });
  assert.equal(a.partita_iva_dichiarata, 'DE123456789'); assert.equal(a.esente_shopify, false);
  const discordante = normalizzaOrdineShopify({ ...originale, note_attributes: [{ name: 'VAT', value: 'DE123' }, { name: 'VAT ID', value: 'DE999' }] });
  assert.equal(discordante.partita_iva_dichiarata, null); assert.equal(discordante.partita_iva_discordante, true);
  assert.equal(valutaOrdineShopify(discordante).verifica_iva, true);
  assert.match(valutaOrdineShopify(discordante).messaggio_iva, /Partite IVA discordanti/);
});
test('PS e PSMI attendono il pagamento completo, non bastano autorizzazione o acconto', () => {
  for (const service of ['Programma Scambio', 'Programma Scambio Made in Italy']) {
    for (const financial_status of ['pending', 'authorized', 'partially_paid']) {
      const o = normalizzaOrdineShopify({ ...originale, financial_status, line_items: [{ ...originale.line_items[0], variant_title: service }] });
      assert.equal(valutaOrdineShopify(o).pronto_ordine, false);
    }
  }
  assert.equal(valutaOrdineShopify(normalizzaOrdineShopify(originale)).pronto_ordine, true);
});
test('RE e RI consentono stesura senza incasso; carrelli misti con scambio richiedono pagamento', () => {
  for (const variant_title of ['Riparazione Elettronica', 'Riparazione Idraulica']) {
    const o = normalizzaOrdineShopify({ ...originale, financial_status: 'pending', line_items: [{ ...originale.line_items[0], variant_title }] });
    assert.equal(valutaOrdineShopify(o).pronto_ordine, true);
    assert.equal(valutaOrdineShopify({ ...o, servizi: [...o.servizi, 'PS'] }).pronto_ordine, false);
  }
});
test('prove e annullamenti non entrano nei contatori operativi; rimborsi richiedono controllo', () => {
  for (const delta of [{ test: true }, { cancelled_at: '2026-10-25T22:00:00Z' }, { financial_status: 'refunded' }, { financial_status: 'voided' }]) {
    const v = valutaOrdineShopify(normalizzaOrdineShopify({ ...originale, ...delta }));
    assert.equal(v.attivo, false); assert.equal(v.pronto_ordine, false); assert.equal(v.verifica_iva, false);
  }
  assert.equal(valutaOrdineShopify(normalizzaOrdineShopify({ ...originale, financial_status: 'partially_refunded' })).pronto_ordine, false);
});
test('varianti sconosciute e descrizioni che menzionano pagamento non attivano l’ordine', () => {
  assert.equal(servizioShopify('Accessorio compatibile PS'), 'da_verificare');
  assert.equal(servizioShopify('Programma Scambio Made in Italy'), 'PSMI');
  assert.equal(valutaOrdineShopify(normalizzaOrdineShopify({ ...originale, line_items: [{ title: 'Pagato PS', variant_title: '', quantity: 1 }] })).pronto_ordine, false);
});
