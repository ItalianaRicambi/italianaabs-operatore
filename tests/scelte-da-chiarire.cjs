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
