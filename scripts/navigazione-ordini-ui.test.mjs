import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire, Module } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';

// Componenti reali e DOM locale. Fonti e azioni remote sostituite; nessuna scrittura.
const base = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const nativeRequire = createRequire(import.meta.url), cache = new Map();
const e = React.createElement;
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const pratica = (n, stato = 'da_evadere') => ({ pratica_id: id(n), numero_pratica: n, stato, targa: `TEST${n}`, stato_fatturazione: 'non_applicabile', shopify_order_id: null });
const shopify = (n, praticaId, stato = 'da_evadere') => ({ id: `shop-${n}`, pratica_id: praticaId, dati: { ordine_id: String(n), numero: `#${n}`, stato_evasione: stato, servizi: [], articoli: [], stato_pagamento: 'paid' }, valutazione: {} });
const dati = { errori: [], shopify: [shopify(101, id(1)), shopify(102, null), shopify(103, id(8), 'evaso')],
  pratiche: [pratica(2), pratica(3), pratica(4, 'da_verificare'), pratica(5, 'evaso')],
  verifiche: [{ id: 'v1', pratica_id: id(6), numero_pratica: 6, evento_at: '2026-11-17T10:00:00Z' },
    { id: 'v2', pratica_id: id(6), numero_pratica: 6, evento_at: '2026-11-17T11:00:00Z' },
    { id: 'v3', pratica_id: id(7), numero_pratica: 7, evento_at: '2026-11-17T12:00:00Z' }] };
function load(path) {
  if (cache.has(path)) return cache.get(path).exports;
  const mod = new Module(path); cache.set(path, mod); mod.filename = path;
  mod.require = name => {
    if (name === 'next/link') return { __esModule: true, default: props => { const clean = { ...props }; delete clean.prefetch; return e('a', clean); } };
    if (name === 'next/navigation') return { redirect: () => { throw Error('Unexpected redirect'); } };
    if (name.endsWith('/operatore')) return { getOperatoreAttivo: async () => 'Operatore test' };
    if (name.endsWith('/codaOrdiniServer')) return { leggiCodaOrdini: async () => dati };
    if (name.endsWith('/CoperturaShopify')) return { CoperturaShopify: () => null };
    if (name.endsWith('/IdentitaOperatore')) return { BarraOperatore: () => null };
    if (name.endsWith('/FormEvasione')) return { FormEvasione: () => null };
    if (name.startsWith('.')) {
      let child = resolve(dirname(path), name);
      if (!/\.[cm]?[jt]sx?$/.test(child)) {
        try { readFileSync(child + '.tsx'); child += '.tsx'; } catch { child += '.ts'; }
      }
      return load(child);
    }
    return nativeRequire(name);
  };
  mod._compile(ts.transpileModule(readFileSync(path, 'utf8'), {
    compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true }, fileName: path,
  }).outputText, path);
  return mod.exports;
}
const { default: Ordini } = load(resolve(base, 'app/ordini/page.tsx'));
const { CodaOrdini } = load(resolve(base, 'app/components/CodaOrdini.tsx'));
const { AvvisiOrdini, AvvisoOrdine } = load(resolve(base, 'app/components/AvvisoOrdine.tsx'));
const { ContestoNavigazioneElenco, NavigazionePratica } = load(resolve(base, 'app/components/NavigazionePratiche.tsx'));
async function mount(t, element) {
  const dom = new JSDOM('<main id="root"></main>', { url: 'https://dashboard.test/ordini' });
  globalThis.window = dom.window; globalThis.document = dom.window.document;
  globalThis.HTMLElement = dom.window.HTMLElement; globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const { createRoot } = await import('react-dom/client');
  const root = createRoot(document.getElementById('root'));
  await act(() => root.render(element));
  t.after(async () => { await act(() => root.unmount()); dom.window.close(); });
  return root;
}
function propsFrom(href) {
  const url = new URL(href, 'https://dashboard.test');
  return { praticaId: url.pathname.split('/').pop(), nav: url.searchParams.get('nav'), filtro: url.searchParams.get('filtro'), cerca: url.searchParams.get('cerca') || '' };
}
const ritorno = () => [...document.querySelectorAll('a')].find(a => a.textContent.includes('Torna'))?.getAttribute('href');
const linkPratiche = () => [...document.querySelectorAll('a')].filter(a => a.getAttribute('href').startsWith('/pratica/'));

test('ordini aperti: Shopify collegato, locali e limiti; mai ordini orfani, verifiche o evasi nelle frecce', async t => {
  const root = await mount(t, await Ordini());
  const href = document.querySelector(`#pratica-${id(2)} a`).getAttribute('href');
  const p = propsFrom(href);
  assert.equal(p.filtro, 'evasioni_aperte'); assert.ok(p.nav);
  await act(() => root.render(e(NavigazionePratica, p)));
  assert.match(document.body.textContent, /Ordini da evadere · Pratica 2 di 3/);
  assert.equal(ritorno(), `/ordini#pratica-${id(2)}`);
  const prev = document.querySelector('a[aria-label^="Pratica precedente"]').getAttribute('href');
  const next = document.querySelector('a[aria-label^="Pratica successiva"]').getAttribute('href');
  assert.equal(propsFrom(prev).praticaId, id(1)); assert.equal(propsFrom(next).praticaId, id(3));
  await act(() => root.render(e(NavigazionePratica, propsFrom(prev))));
  assert.equal(ritorno(), '/ordini#shopify-101');
  assert.equal(document.querySelector('button[disabled]').textContent, '← Precedente');
  await act(() => root.render(e(NavigazionePratica, propsFrom(next))));
  assert.equal(document.querySelector('button[disabled]').textContent, 'Successiva →');
});

test('verifiche: pratica duplicata mostrata una volta nelle frecce e categoria separata', async t => {
  const root = await mount(t, await Ordini());
  const links = linkPratiche().filter(a => a.textContent.includes('Verifica offerta'));
  assert.equal(links.length, 3);
  assert.ok(links[0].getAttribute('href').endsWith('#sezione-offerta'));
  await act(() => root.render(e(NavigazionePratica, propsFrom(links[0].getAttribute('href')))));
  assert.match(document.body.textContent, /Pratica 1 di 2/);
  assert.equal(propsFrom(document.querySelector('a[aria-label^="Pratica successiva"]').getAttribute('href')).praticaId, id(7));
});

test('riquadro ordini da evadere usa tutta la coda aperta, non il contesto della home', async t => {
  const root = await mount(t, await CodaOrdini());
  const p = propsFrom(linkPratiche()[0].getAttribute('href'));
  await act(() => root.render(e(NavigazionePratica, p)));
  assert.match(document.body.textContent, /Ordini da evadere · Pratica 2 di 3/);
  assert.equal(ritorno(), `/ordini#pratica-${id(2)}`);
});

test('riquadro fatturazione: cinque scorciatoie, sequenza completa e nessuna fatturata', async t => {
  const pratiche = Array.from({ length: 9 }, (_, i) => ({ id: id(20+i), codice_pratica: `ABS-${20+i}`, tipo_flusso: 'commerciale', stato_commerciale: 'ordine_acquisito', stato_fatturazione: i===8 ? 'fatturato' : 'da_fatturare' }));
  const root = await mount(t, e(ContestoNavigazioneElenco, { chiave: id(999), filtro: 'oggi', etichetta: 'Oggi', cerca: '', voci: [] }, e(AvvisiOrdini, { pratiche })));
  const links = linkPratiche(); assert.equal(links.length, 5);
  const p = propsFrom(links[4].getAttribute('href'));
  assert.equal(p.filtro, 'ordini_confermati'); assert.notEqual(p.nav, id(999));
  assert.ok(links[4].getAttribute('href').endsWith('#sezione-amministrazione'));
  await act(() => root.render(e(NavigazionePratica, p)));
  assert.match(document.body.textContent, /Ordini da fatturare · Pratica 5 di 8/);
  assert.equal(propsFrom(document.querySelector('a[aria-label^="Pratica successiva"]').getAttribute('href')).praticaId, id(25));
  assert.equal(ritorno(), `/?filtro=ordini_confermati#pratica-${id(24)}`);
});

test('ritorno home conserva ricerca e pagina; avviso dentro la scheda non perde la query nav', async t => {
  const root = await mount(t, e(ContestoNavigazioneElenco, { chiave: id(990), filtro: 'ordini_confermati', etichetta: 'Ordini', cerca: 'ABS', ritorno: '/?filtro=ordini_confermati&cerca=ABS', righePerPagina: 5, voci: Array.from({length:8},(_,i)=>({id:id(30+i),codice:`ABS-${i}`})) }));
  await act(() => root.render(e(NavigazionePratica, { praticaId: id(36), nav: id(990), filtro: 'ordini_confermati', cerca: 'ABS' })));
  assert.equal(ritorno(), `/?filtro=ordini_confermati&cerca=ABS&pagina=2#pratica-${id(36)}`);
  await act(() => root.render(e(AvvisoOrdine, { pratica: { id:id(36), tipo_flusso:'commerciale', stato_commerciale:'ordine_acquisito', stato_fatturazione:'da_fatturare' } })));
  assert.equal(document.querySelector('a').getAttribute('href'), '#sezione-amministrazione');
});

test('contesto mancante o scaduto: nessun elenco inventato e ritorno agli ordini', async t => {
  await mount(t, e(NavigazionePratica, { praticaId:id(2), nav:id(900), filtro:'evasioni_aperte' }));
  assert.equal(document.querySelectorAll('button[disabled]').length, 2);
  assert.equal(ritorno(), `/ordini#pratica-${id(2)}`);
});

test('storage manipolato: URL esterni o percorsi non ammessi vengono rifiutati', async t => {
  const root = await mount(t, e('p', null, 'test'));
  for (const [i, url] of ['//evil.test','https://evil.test','/\\evil.test','/ordini/../altro','/?x=1#evil'].entries()) {
    const key = id(700+i);
    window.sessionStorage.setItem('italianaabs:navigazione:v1:'+key, JSON.stringify({ versione:1, chiave:key, filtro:'evasioni_aperte', etichetta:'Test', cerca:'', ritorno:url, salvatoIl:Date.now(), voci:[{id:id(1),codice:'A'},{id:id(2),codice:'B'}] }));
    await act(() => root.render(e(NavigazionePratica, { praticaId:id(1),nav:key,filtro:'evasioni_aperte' })));
    assert.equal(document.querySelectorAll('button[disabled]').length, 2);
    assert.equal(ritorno(), `/ordini#pratica-${id(1)}`);
  }
});

test('protezione modifiche non salvate resta attiva sulle nuove frecce', async t => {
  const root = await mount(t, await Ordini());
  const p = propsFrom(document.querySelector(`#pratica-${id(2)} a`).getAttribute('href'));
  await act(() => root.render(e(React.Fragment, null, e(NavigazionePratica, p), e('form', { 'data-monitoraggio-modifiche':'gestito', 'data-modifiche-non-salvate':'true' }, e('input', {name:'nota'})))));
  let richieste=0; window.confirm=()=>{richieste++;return false;};
  const event = new window.MouseEvent('click', {bubbles:true,cancelable:true});
  document.querySelector('a[aria-label^="Pratica successiva"]').dispatchEvent(event);
  assert.equal(richieste,1); assert.equal(event.defaultPrevented,true);
});
