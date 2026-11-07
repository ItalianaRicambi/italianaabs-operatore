import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire, Module } from 'node:module';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';
import React, { act } from 'react';
import { JSDOM, VirtualConsole } from 'jsdom';

// Test DOM dei componenti reali, senza server, credenziali, fetch o azioni remote.
const base = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const nativeRequire = createRequire(import.meta.url);
const cache = new Map();
function load(path) {
  if (cache.has(path)) return cache.get(path).exports;
  const mod = new Module(path);
  cache.set(path, mod);
  mod.filename = path;
  mod.require = name => {
    if (name === 'next/link') return { __esModule: true, default: (props) => { const clean = { ...props }; delete clean.prefetch; return React.createElement('a', clean); } };
    if (name.endsWith('/IdentitaOperatore')) return { BarraOperatore: () => React.createElement('header', null, 'Operatore test') };
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
    compilerOptions: { jsx: ts.JsxEmit.ReactJSX, module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022, esModuleInterop: true },
    fileName: path,
  }).outputText, path);
  return mod.exports;
}
const { SchedaPratica, CardPratica, SezionePraticaVisibile } = load(resolve(base, 'app/components/SchedaPratica.tsx'));
const { HomeOggi } = load(resolve(base, 'app/components/HomeOggi.tsx'));
const { ContestoNavigazioneElenco, NavigazionePratica } = load(resolve(base, 'app/components/NavigazionePratiche.tsx'));
const { modificheNonSalvate } = load(resolve(base, 'app/lib/modifichePratica.ts'));
const e = React.createElement;
const id = i => `00000000-0000-4000-8000-${String(i).padStart(12, '0')}`;
async function mount(t, element, hash = '') {
  const errors = [];
  const virtualConsole = new VirtualConsole();
  virtualConsole.on('jsdomError', error => errors.push(error));
  const dom = new JSDOM('<main id="root"></main>', { url: `https://dashboard.test/pratica/${id(1)}${hash}`, virtualConsole });
  globalThis.window = dom.window;
  globalThis.document = dom.window.document;
  globalThis.HTMLElement = dom.window.HTMLElement;
  globalThis.IS_REACT_ACT_ENVIRONMENT = true;
  const { createRoot } = await import('react-dom/client');
  const root = createRoot(document.getElementById('root'));
  await act(() => root.render(element));
  t.after(async () => { await act(() => root.unmount()); dom.window.close(); assert.deepEqual(errors, []); });
  return { root, dom, document: dom.window.document };
}
function button(text) { return [...document.querySelectorAll('button')].find(el => el.textContent === text); }
function visible(el) { return !el.closest('[hidden]'); }
const azione = { titolo: 'Preparare il preventivo', motivo: 'Dati completi da verificare.', area: 'pratiche', sezione: 'offerta', stato: 'da_lavorare', urgente: false };

test('le sezioni mantengono montati i form e i dati non salvati senza invocare azioni', async t => {
  let invii = 0;
  await mount(t, e(SchedaPratica, { praticaId: id(1), azione, protetta: true },
    e(NavigazionePratica, { praticaId: id(1) }),
    e(CardPratica, { titolo: 'Cliente e veicolo' }, e('form', { onSubmit: event => { event.preventDefault(); invii++; } }, e('input', { name: 'targa', defaultValue: 'DEMO' }))),
    e(SezionePraticaVisibile, { sezioni: ['offerta'] }, e('p', { id: 'offerta' }, 'Offerta test')),
    e(CardPratica, { titolo: 'Azioni operatore' }, e('button', { onClick: () => invii++ }, 'Esegui comando')),
    e(CardPratica, { titolo: 'Note interne operatore' }, e('p', { id: 'nota' }, 'Nota operatore')),
    e(CardPratica, { titolo: 'Cliente fiscale' }, e('p', { id: 'fiscale' }, 'Cliente test')),
  ));
  const input = document.querySelector('input');
  input.dispatchEvent(new window.FocusEvent('focusin', { bubbles: true }));
  input.value = 'MODIFICA NON SALVATA';
  input.dispatchEvent(new window.Event('input', { bubbles: true }));
  assert.equal(modificheNonSalvate(), true);
  assert.equal(visible(document.getElementById('offerta')), false);
  await act(() => button('Offerta e ordine').click());
  assert.equal(visible(input), false);
  assert.equal(visible(document.getElementById('offerta')), true);
  assert.equal(visible(document.getElementById('nota')), true);
  assert.equal(window.location.hash, '#sezione-offerta');
  await act(() => button('Amministrazione').click());
  assert.equal(visible(document.getElementById('fiscale')), true);
  assert.equal(visible(document.getElementById('offerta')), false);
  await act(() => button('Dati e diagnosi').click());
  assert.equal(document.querySelector('input'), input);
  assert.equal(input.value, 'MODIFICA NON SALVATA');
  assert.equal(modificheNonSalvate(), true);
  assert.equal(document.querySelector('details').open, false);
  await act(() => button('Vista completa').click());
  assert.equal(document.querySelectorAll('[hidden]').length, 0);
  assert.equal(invii, 0);
});

test('il collegamento profondo apre la sezione suggerita e ignora hash sconosciuti', async t => {
  await mount(t, e(SchedaPratica, { praticaId: id(1), azione, protetta: false }), '#sezione-logistica');
  assert.equal(button('Logistica e assistenza').getAttribute('aria-pressed'), 'true');
  await act(() => { window.location.hash = '#inesistente'; window.dispatchEvent(new window.HashChangeEvent('hashchange')); });
  assert.equal(button('Logistica e assistenza').getAttribute('aria-pressed'), 'true');
  await act(() => button('Apri la sezione →').click());
  assert.equal(button('Offerta e ordine').getAttribute('aria-pressed'), 'true');
});

const pratiche = Array.from({ length: 12 }, (_, i) => ({ id: id(i + 1), codice_pratica: `DEMO-${i + 1}`, nome_cliente: 'Cliente dimostrativo', tipo_flusso: 'commerciale', coda: 'DA PREVENTIVARE', stato_commerciale: 'da_preventivare' }));
const props = { operatore: 'Operatore 1', pratiche, righe: pratiche, filtro: 'oggi', etichetta: 'Da lavorare', cerca: '', pagina: 2, giornoRoma: '2026-11-07', errore: null, controllo: { fermo: true, ultimo: null, aperte: 2 }, email: null, controlli: e('p', null, 'Controlli esistenti') };

test('home: cinque righe, filtri e pagine coerenti, avviso di controllo fermo sempre visibile', async t => {
  await mount(t, e(HomeOggi, props));
  const righe = [...document.querySelectorAll('article')];
  assert.equal(righe.length, 5);
  assert.match(righe[0].textContent, /DEMO-6/);
  assert.match(righe[4].textContent, /DEMO-10/);
  assert.match(document.querySelector('[role="alert"]').textContent, /fermo o in errore/);
  assert.equal(document.querySelectorAll('nav[aria-label="Aree di lavoro"] a').length, 5);
  assert.match(righe[0].querySelector('a').getAttribute('href'), /filtro=oggi.*#sezione-offerta$/);
  const pagine = [...document.querySelectorAll('nav[aria-label="Pagine dell’elenco"] a')].map(a => a.getAttribute('href'));
  assert.deepEqual(pagine, ['/?filtro=oggi', '/?filtro=oggi&pagina=3']);
  assert.equal(document.querySelector('a[href="/?vista=classica"]') !== null, true);
});

test('home: pagine fuori limite si fermano all’ultima; errori non mostrano conteggi rassicuranti', async t => {
  await mount(t, e(HomeOggi, { ...props, pagina: 99999, errore: 'Attività non disponibili' }));
  assert.equal(document.querySelectorAll('article').length, 2);
  assert.match(document.querySelector('article').textContent, /DEMO-11/);
  assert.match(document.body.textContent, /Dati parziali o non disponibili/);
  assert.match(document.body.textContent, /elenco parziale/);
  assert.equal([...document.querySelectorAll('p')].filter(p => p.textContent === '—').length, 4);
});

test('il ritorno conserva ricerca, filtro e la pagina della pratica raggiunta con le frecce', async t => {
  const chiave = id(99);
  const { root } = await mount(t, e(ContestoNavigazioneElenco, { chiave, filtro: 'oggi', etichetta: 'Da lavorare', cerca: 'DEMO', ritorno: '/?filtro=oggi&cerca=DEMO&pagina=1', righePerPagina: 5, voci: pratiche.map(p => ({ id: p.id, codice: p.codice_pratica })) }));
  await act(() => root.render(e(NavigazionePratica, { praticaId: id(7), nav: chiave, filtro: 'oggi', cerca: 'DEMO' })));
  const ritorno = [...document.querySelectorAll('a')].find(a => /Torna/.test(a.textContent));
  assert.equal(ritorno.getAttribute('href'), `/?filtro=oggi&cerca=DEMO&pagina=2#pratica-${id(7)}`);
  assert.match(document.querySelector('a[aria-label="Pratica precedente: DEMO-6"]').getAttribute('href'), new RegExp(id(6)));
});

test('senza storage il filtro tutte resta esplicito e non torna per errore a Oggi', async t => {
  await mount(t, e(NavigazionePratica, { praticaId: id(1), filtro: 'tutte' }));
  assert.equal(document.querySelector('a').getAttribute('href'), `/?filtro=tutte#pratica-${id(1)}`);
});
