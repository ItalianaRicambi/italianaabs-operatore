const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const ts = require('typescript');
const { JSDOM } = require('jsdom');

const root = path.resolve(__dirname, '..');
function carica(file, mocks = {}) {
  const filename = path.join(root, file);
  const m = new Module(filename, module);
  m.filename = filename;
  m.paths = Module._nodeModulePaths(path.dirname(filename));
  const originale = m.require.bind(m);
  m.require = nome => nome in mocks ? mocks[nome] : originale(nome);
  m._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, jsx: ts.JsxEmit.ReactJSX, target: ts.ScriptTarget.ES2020 },
  }).outputText, filename);
  return m.exports;
}

test('la scelta da chiarire montata via SPA non crea una falsa modifica; le modifiche reali restano protette', async () => {
  const dom = new JSDOM('<main><div id="root"></div></main>', { url: 'http://localhost' });
  const precedenti = {};
  for (const nome of ['window', 'document', 'HTMLElement', 'HTMLInputElement', 'HTMLSelectElement', 'Event']) {
    precedenti[nome] = global[nome]; global[nome] = dom.window[nome];
  }
  global.IS_REACT_ACT_ENVIRONMENT = true;
  const React = require('react');
  const { createRoot } = require('react-dom/client');
  const guardia = carica('app/lib/modifichePratica.ts');
  const flussi = carica('app/lib/flussiOperativi.ts');
  const { CorrezioneSceltaCliente } = carica('app/components/CorrezioneSceltaCliente.tsx', {
    '../lib/flussiOperativi': flussi,
    '../pratica/[id]/actions': { correggiSceltaCliente: async () => ({ ok: false, messaggio: '' }) },
  });
  const app = createRoot(document.getElementById('root'));
  let ferma;
  try {
    await React.act(async () => app.render(React.createElement(CorrezioneSceltaCliente, {
      praticaId: 'test', scelta: { stato: 'da_chiarire', opzione_id: null }, offerte: [], opzioni: [],
    })));
    const stato = document.querySelector('select[name="stato"]');
    assert.equal(stato.value, 'da_chiarire');
    assert.equal(Array.from(stato.options).some(o => o.defaultSelected), false,
      'riproduce la discrepanza tra select React e default HTML nella navigazione SPA');
    ferma = guardia.avviaControlloModifiche(document);
    assert.equal(guardia.modificheNonSalvate(), false, 'form mai modificata');
    await React.act(async () => { stato.value = 'confermata'; stato.dispatchEvent(new Event('change', { bubbles: true })); });
    assert.equal(guardia.modificheNonSalvate(), true, 'scelta non salvata');
    await React.act(async () => { stato.value = 'da_chiarire'; stato.dispatchEvent(new Event('change', { bubbles: true })); });
    assert.equal(guardia.modificheNonSalvate(), false, 'ripristino del valore iniziale');
    const dati = document.createElement('form');
    dati.dataset.monitoraggioModifiche = 'gestito'; dati.dataset.modificheNonSalvate = 'true';
    document.querySelector('main').append(dati);
    assert.equal(guardia.modificheNonSalvate(), true, 'modulo dati ancora da salvare');
    dati.dataset.modificheNonSalvate = 'false';
    assert.equal(guardia.modificheNonSalvate(), false, 'modulo dati appena confermato, scelta da chiarire intatta');
    const nota = document.querySelector('textarea');
    await React.act(async () => {
      const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLTextAreaElement.prototype, 'value').set;
      setter.call(nota, 'Nota ancora da salvare'); nota.dispatchEvent(new Event('input', { bubbles: true }));
    });
    assert.equal(guardia.modificheNonSalvate(), true, 'salvare i dati non cancella una nota in un’altra form');
  } finally {
    ferma?.(); await React.act(async () => app.unmount()); dom.window.close();
    for (const nome of Object.keys(precedenti)) {
      if (precedenti[nome] === undefined) delete global[nome]; else global[nome] = precedenti[nome];
    }
    delete global.IS_REACT_ACT_ENVIRONMENT;
  }
});

test('campi precompilati, checkbox, form dinamiche, ricerca e cambio pratica', async () => {
  const dom = new JSDOM('<main><form><input name="marca" value="Suzuki"><input type="checkbox" name="verificata"></form><form method="get"><input name="cerca"></form></main>');
  const doc = dom.window.document;
  const guardia = carica('app/lib/modifichePratica.ts');
  const ferma = guardia.avviaControlloModifiche(doc);
  try {
    const marca = doc.querySelector('[name="marca"]');
    marca.value = 'Suzuki aggiornato dal server';
    assert.equal(guardia.modificheNonSalvate(), false);
    marca.dispatchEvent(new dom.window.Event('focusin', { bubbles: true }));
    marca.value = 'Fiat'; marca.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
    assert.equal(guardia.modificheNonSalvate(), true);
    marca.value = 'Suzuki aggiornato dal server'; marca.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
    assert.equal(guardia.modificheNonSalvate(), false);
    const checkbox = doc.querySelector('[type="checkbox"]');
    checkbox.checked = true; checkbox.dispatchEvent(new dom.window.Event('change', { bubbles: true }));
    assert.equal(guardia.modificheNonSalvate(), true);
    checkbox.checked = false; checkbox.dispatchEvent(new dom.window.Event('change', { bubbles: true }));
    const cerca = doc.querySelector('[name="cerca"]');
    cerca.value = 'ricerca'; cerca.dispatchEvent(new dom.window.Event('input', { bubbles: true }));
    assert.equal(guardia.modificheNonSalvate(), false, 'una ricerca non è un dato della pratica da salvare');
    const dinamica = doc.createElement('form'); dinamica.innerHTML = '<input name="nuovo" value="iniziale">';
    doc.querySelector('main').append(dinamica); await Promise.resolve();
    dinamica.querySelector('input').value = 'modificato';
    dinamica.querySelector('input').dispatchEvent(new dom.window.Event('change', { bubbles: true }));
    assert.equal(guardia.modificheNonSalvate(), true);
    dinamica.remove(); assert.equal(guardia.modificheNonSalvate(), false);
    ferma();
    const altro = new JSDOM('<main><form><select><option>a</option><option selected>b</option></select></form></main>');
    const fermaAltro = guardia.avviaControlloModifiche(altro.window.document);
    assert.equal(guardia.modificheNonSalvate(), false, 'nessuna modifica ereditata dalla pratica precedente');
    fermaAltro(); altro.window.close();
  } finally { ferma(); dom.window.close(); }
});
