const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');

const filename = path.resolve(__dirname, '../app/lib/flussiOperativi.ts');
const m = new Module(filename, module);
m.filename = filename;
m.paths = Module._nodeModulePaths(path.dirname(filename));
m._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
}).outputText, filename);
const { sceltaClienteDaChiarire } = m.exports;

const segnali = [
  { stato: 'da_chiarire', offerta_successiva: false, prezzo_da_verificare: false },
  { stato: 'modifica_da_verificare', offerta_successiva: false, prezzo_da_verificare: false },
  { stato: 'confermata', offerta_successiva: true, prezzo_da_verificare: false },
  { stato: 'confermata', offerta_successiva: false, prezzo_da_verificare: true },
];
const aperta = scelta => ({
  tipo_flusso: 'commerciale', stato_commerciale: 'ordine_acquisito',
  stato_fatturazione: 'da_fatturare', scelta_cliente: scelta,
});

test('i quattro casi reali fatturati escono dalla coda senza cancellare lo storico', () => {
  const casi = [[1029, segnali[3]], [1033, segnali[0]], [1375, segnali[2]], [1735, segnali[0]]];
  const pratiche = casi.map(([numero, scelta]) => ({
    ...aperta(scelta), numero, stato_fatturazione: 'fatturato',
  }));
  const storico = structuredClone(pratiche);
  assert.deepEqual(pratiche.filter(sceltaClienteDaChiarire), []);
  assert.deepEqual(pratiche, storico);
});

test('una futura pratica esce appena fatturata anche se K segnala nuovamente una scelta ambigua', () => {
  for (const scelta of segnali) {
    const pratica = aperta(scelta);
    assert.equal(sceltaClienteDaChiarire(pratica), true);
    pratica.stato_fatturazione = 'fatturato';
    assert.equal(sceltaClienteDaChiarire(pratica), false);
    pratica.scelta_cliente = { ...scelta, stato: 'da_chiarire', offerta_successiva: true, prezzo_da_verificare: true };
    assert.equal(sceltaClienteDaChiarire(pratica), false);
  }
});

test('tutti i segnali reali restano visibili sulle vendite aperte, senza falsi positivi', () => {
  for (const scelta of segnali) assert.equal(sceltaClienteDaChiarire(aperta(scelta)), true);
  for (const scelta of [null, undefined, { stato: 'confermata', offerta_successiva: false, prezzo_da_verificare: false }]) {
    assert.equal(sceltaClienteDaChiarire(aperta(scelta)), false);
  }
});

test('vendite chiuse, rifiutate e assistenza non entrano nella coda commerciale', () => {
  for (const scelta of segnali) {
    for (const stato_commerciale of ['chiuso', 'rifiutato']) {
      assert.equal(sceltaClienteDaChiarire({ ...aperta(scelta), stato_commerciale }), false);
    }
    const assistenza = { ...aperta(scelta), tipo_flusso: 'assistenza', stato_assistenza: 'in_gestione' };
    assert.equal(sceltaClienteDaChiarire(assistenza), false);
    assert.equal(assistenza.stato_assistenza, 'in_gestione');
  }
});

test('la Dashboard usa la stessa regola per contatore ed elenco e conserva le fatturate nello storico', async () => {
  const React = require('react');
  const { renderToStaticMarkup } = require('react-dom/server');
  const { JSDOM } = require('jsdom');
  const root = path.resolve(__dirname, '..');
  const carica = (file, mocks = {}) => {
    const filename = path.join(root, file);
    const loaded = new Module(filename, module);
    loaded.filename = filename;
    loaded.paths = Module._nodeModulePaths(path.dirname(filename));
    const originale = loaded.require.bind(loaded);
    loaded.require = nome => nome in mocks ? mocks[nome] : originale(nome);
    loaded._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, target: ts.ScriptTarget.ES2020 },
    }).outputText, filename);
    return loaded.exports;
  };
  const pratiche = [1029, 1033, 1375, 1735, 9999].map((numero, i) => ({
    ...aperta(null), id: String(numero), codice_pratica: `ABS-${String(numero).padStart(6, '0')}`,
    created_at: '2026-10-01T10:00:00Z', nome_cliente: `Cliente ${numero}`,
    stato_fatturazione: i < 4 ? 'fatturato' : 'da_fatturare',
    data_fattura: i < 4 ? new Date().toISOString() : null,
    stato_completezza: 'completa_da_preventivare', coda: 'FATTURATA', priorita: 10,
  }));
  const scelte = [segnali[3], segnali[0], segnali[2], segnali[0], segnali[1]]
    .map((scelta, i) => ({ ...scelta, pratica_id: pratiche[i].id, evidenza: 'Storico' }));
  const Home = carica('app/page.tsx', {
    './lib/flussiOperativi': m.exports,
    './lib/dashboardMensile': carica('app/lib/dashboardMensile.ts'),
    './lib/fatturazione': carica('app/lib/fatturazione.ts'),
    './lib/supabaseRest': { fetchTutteLePagine: async url => {
      const tabella = new URL(url).pathname.split('/').pop();
      return ({ v_coda_operatore_tempi: pratiche, pratiche, v_scelte_cliente: scelte })[tabella] || [];
    } },
    './operatore': { getOperatoreAttivo: async () => 'Operatore test' },
    './components/IdentitaOperatore': { AccessoOperatore: () => null, BarraOperatore: () => null },
    './components/AbbinamentoPresa': { AbbinamentoPresa: () => null },
    './components/NavigazionePratiche': {
      ContestoNavigazioneElenco: ({ children }) => children,
      ApriPraticaConContesto: ({ children }) => children,
    },
    './lib/glsServer': { leggiEsitiGls: async () => ({ righe: [], errore: null }) },
    './lib/esitiGls': { statoGlsAttuale: () => '', presaPrenotata: () => false, etichettaPresa: () => '' },
    './lib/prenotazioniPrese': { dataPresaIt: () => '' },
    './lib/emailLogisticaServer': { rpcEmail: async () => null },
    'next/link': { __esModule: true, default: ({ href, children, className }) => React.createElement('a', { href, className }, children) },
  }).default;
  const precedenti = [process.env.SUPABASE_URL, process.env.SUPABASE_SECRET_KEY];
  process.env.SUPABASE_URL = 'https://database.invalid';
  process.env.SUPABASE_SECRET_KEY = 'test-only';
  try {
    const dom = new JSDOM(renderToStaticMarkup(await Home({ searchParams: Promise.resolve({ filtro: 'scelte_da_chiarire' }) })));
    assert.equal(dom.window.document.querySelector('a[href="/?filtro=scelte_da_chiarire"] .text-4xl').textContent, '1');
    const righe = dom.window.document.querySelectorAll('tbody tr');
    assert.equal(righe.length, 1);
    assert.match(righe[0].textContent, /Cliente 9999/);
    dom.window.close();
    const storico = new JSDOM(renderToStaticMarkup(await Home({ searchParams: Promise.resolve({ filtro: 'fatture_mese_corrente' }) })));
    assert.equal(storico.window.document.querySelectorAll('tbody tr').length, 4);
    storico.window.close();
  } finally {
    for (const [i, nome] of ['SUPABASE_URL', 'SUPABASE_SECRET_KEY'].entries()) {
      if (precedenti[i] === undefined) delete process.env[nome]; else process.env[nome] = precedenti[i];
    }
  }
});
