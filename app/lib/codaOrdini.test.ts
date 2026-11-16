import test from 'node:test';
import assert from 'node:assert/strict';
test('annullamento Shopify non riappare come duplicato locale; riferimento non acquisito resta in verifica',()=>{
 const s=shop();s.dati.annullato=true;s.pratica_id='p1';
 assert.equal(classificaCoda([s],[pratica()]).praticheAperte.length,0);
 const c=classificaCoda([],[pratica({shopify_order_id:'123'})]);
 assert.equal(c.praticheAperte.length,0);assert.equal(c.praticheDaVerificare.length,1);
});
import { classificaCoda, type EvasionePratica, type ShopifyCoda } from './codaOrdini.ts';
const pratica = (delta: Partial<EvasionePratica> = {}):EvasionePratica => ({pratica_id:'p1',numero_pratica:1,targa:'AB123CD',stato:'da_evadere',revisione:1,nota:'Ordine confermato',updated_at:'2026-11-16T00:00:00Z',stato_fatturazione:'fatturato',shopify_order_id:null,blocco_operatore:false,...delta});
const shop = (delta: Partial<ShopifyCoda> = {}):ShopifyCoda => ({id:'s1',pratica_id:null,conflitto:false,dati:{ordine_id:'1',numero:'#1',stato_evasione:'da_evadere',test:false,annullato:false,stato_pagamento:'paid'},...delta});
test('Shopify orfano è visibile e fattura non chiude la pratica da evadere',()=>{
 const c=classificaCoda([shop()],[pratica()]);
 assert.equal(c.shopifyAperti.length,1); assert.equal(c.praticheAperte.length,1);
});
test('collegamento esatto evita doppio conteggio, non viene dedotto da cliente o targa',()=>{
 for (const [s,p] of [[shop({pratica_id:'p1'}),pratica()],[shop(),pratica({shopify_order_id:'gid://shopify/Order/1'})]] as const) {
 const c=classificaCoda([s],[p]); assert.equal(c.shopifyAperti.length,1);assert.equal(c.praticheAperte.length,0);
 }
});
test('evaso, stato ignoto, conflitti e vecchie fatture restano categorie distinte',()=>{
 const s=shop();
 const c=classificaCoda([{...s,dati:{...s.dati,stato_evasione:'evaso'}},{...s,id:'s2',dati:{...s.dati,ordine_id:'2',stato_evasione:undefined}},{...s,id:'s3',conflitto:true}], [pratica({stato:'da_verificare'})]);
 assert.equal(c.shopifyAperti.length,0);assert.equal(c.shopifyEvasi.length,1);assert.equal(c.shopifyDaVerificare.length,2);assert.equal(c.praticheDaVerificare.length,1);
});
test('annullati, prove, rimborsati non entrano in coda; parziali restano',()=>{
 const s=shop();
 const righe=[{test:true},{annullato:true},{stato_pagamento:'refunded'},{stato_evasione:'parziale'}].map((d,i)=>({...s,id:String(i),dati:{...s.dati,...d}}));
 assert.equal(classificaCoda(righe,[]).shopifyAperti.length,1);
});
