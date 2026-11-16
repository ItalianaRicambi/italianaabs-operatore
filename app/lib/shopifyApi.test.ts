import { test } from 'node:test';
import assert from 'node:assert/strict';
import { normalizzaApi, unisciOrdini, problemaSync, type OrdineApi } from './shopifyApi.ts';
import { valutaOrdineShopify } from './ordiniShopify.ts';

const fixture=():OrdineApi=>({admin_graphql_api_id:'gid://shopify/Order/123',name:'#123',updated_at:'2026-11-16T10:00:00Z',
 test:false,cancelled_at:null,financial_status:'PAID',fulfillment_status:'UNFULFILLED',currency:'EUR',tax_exempt:false,
 currentTotalPriceSet:{shopMoney:{amount:'497.00'}},currentTotalTaxSet:{shopMoney:{amount:'89.62'}},
 line_items:{pageInfo:{hasNextPage:false,endCursor:null},nodes:[{title:'ABS',variant_title:'PS',quantity:1}]}});
function riga(){const dati=normalizzaApi(fixture());return {id:'webhook',dati,valutazione:valutaOrdineShopify(dati),pratica_id:'pratica',conflitto:false,ricevuto_at:'2026-11-16T10:00:00Z'};}
test('API normalizes paid order and exact ID',()=>{const o=normalizzaApi(fixture());assert.equal(o.ordine_id,'123');assert.equal(o.totale,49700);assert.equal(o.stato_evasione,'da_evadere');assert.equal(valutaOrdineShopify(o).pronto_ordine,true);});
test('fulfilled and partial; held/scheduled/unknown never open',()=>{for(const [v,w] of [['FULFILLED','evaso'],['PARTIALLY_FULFILLED','parziale'],['ON_HOLD','da_verificare'],['SCHEDULED','da_verificare'],['NEW_ENUM','da_verificare']])assert.equal(normalizzaApi({...fixture(),fulfillment_status:v}).stato_evasione,w);});
test('truncated lines and unknown payments fail closed',()=>{const f=fixture();f.line_items.pageInfo.hasNextPage=true;assert.throws(()=>normalizzaApi(f));assert.throws(()=>normalizzaApi({...fixture(),financial_status:'NEW'}));});
test('same version API enriches fulfillment without duplicate and preserves operator link',()=>{const w=riga();const api={ordine_id:'123',dati:{...w.dati,stato_evasione:'evaso' as const},verificato_at:'2026-11-16T11:00:00Z'};const rows=unisciOrdini([w],[api]);assert.equal(rows.length,1);assert.equal(rows[0].pratica_id,'pratica');assert.equal(rows[0].dati.stato_evasione,'evaso');});
test('newer webhook wins, older API does not reopen fulfilled order',()=>{const w=riga();w.dati.aggiornato_shopify_at='2026-11-16T12:00:00Z';w.dati.stato_evasione='evaso';assert.equal(unisciOrdini([w],[{ordine_id:'123',dati:normalizzaApi(fixture()),verificato_at:'2026-11-16T13:00:00Z'}])[0].dati.stato_evasione,'evaso');});
test('same version financial difference is a conflict',()=>{const w=riga();assert.equal(unisciOrdini([w],[{ordine_id:'123',dati:{...w.dati,totale:1},verificato_at:w.ricevuto_at}])[0].conflitto,true);});
test('cancellation and existing conflict are never undone',()=>{const w=riga();w.dati.annullato=true;w.conflitto=true;const r=unisciOrdini([w],[{ordine_id:'123',dati:normalizzaApi(fixture()),verificato_at:w.ricevuto_at}])[0];assert.equal(r.dati.annullato,true);assert.equal(r.conflitto,true);assert.equal(r.valutazione.attivo,false);});
test('API-only orders remain visible; records outside API coverage retained',()=>{const w=riga();const other={...normalizzaApi(fixture()),ordine_id:'456'};assert.equal(unisciOrdini([w],[{ordine_id:'456',dati:other,verificato_at:w.ricevuto_at}]).length,2);});
test('health missing, failed, stale or never tested cannot be green',()=>{const s={ultimo_avvio_at:null,ultimo_successo_at:null,errore:null,ordini_letti:0,finestra_da:null};assert.ok(problemaSync(null));assert.ok(problemaSync(s));assert.ok(problemaSync({...s,errore:'fallito'}));assert.ok(problemaSync({...s,ultimo_successo_at:'2026-11-16T10:00:00Z'},Date.parse('2026-11-16T10:16:00Z')));assert.equal(problemaSync({...s,ultimo_successo_at:'2026-11-16T10:00:00Z'},Date.parse('2026-11-16T10:14:00Z')),null);});
