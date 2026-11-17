import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync } from 'node:fs';
import { createRequire, Module } from 'node:module';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';
import React, { act } from 'react';
import { JSDOM } from 'jsdom';

const base=resolve(dirname(fileURLToPath(import.meta.url)), '..');
const nativeRequire=createRequire(import.meta.url);
let esito={ok:false,messaggio:'Destinatario discordante: nessun dato salvato.'};
const ricevuti=[];
const path=resolve(base,'app/components/DocumentoAmministrativo.tsx');
const mod=new Module(path);
mod.require=name=>name.endsWith('/actions') ? {importaDocumentoAmministrativo:async (_prev,data)=>{
  ricevuti.push(data);return esito;
}} : nativeRequire(name);
mod._compile(ts.transpileModule(readFileSync(path,'utf8'),{
  compilerOptions:{jsx:ts.JsxEmit.ReactJSX,module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022,esModuleInterop:true},fileName:path,
}).outputText,path);

test('il modulo conserva selezione e conferma dopo errore; reset solo dopo successo', async t=>{
  const dom=new JSDOM('<main id="root"></main>',{url:'https://dashboard.test'});
  globalThis.window=dom.window;globalThis.document=dom.window.document;
  globalThis.HTMLElement=dom.window.HTMLElement;globalThis.IS_REACT_ACT_ENVIRONMENT=true;
  // FormData DOM per i campi reali; jsdom non espone un file chooser.
  const originalFormData=globalThis.FormData;
  globalThis.FormData=dom.window.FormData;
  const {createRoot}=await import('react-dom/client');
  const root=createRoot(document.getElementById('root'));
  t.after(async()=>{await act(()=>root.unmount());dom.window.close();globalThis.FormData=originalFormData;});
  await act(()=>root.render(React.createElement(mod.exports.ImportazioneDocumentoAmministrativo,{praticaId:'00000000-0000-4000-8000-000000000001'})));
  const form=document.querySelector('form'),check=document.querySelector('[name=verificata]');
  const file=document.querySelector('[name=pdf]');
  let resetCount=0;
  form.addEventListener('reset',()=>{resetCount++;});
  check.checked=true;
  // Il submit sintetico evita solo il chooser/required del browser, non il componente.
  const submit=()=>act(async()=>{form.dispatchEvent(new dom.window.Event('submit',{bubbles:true,cancelable:true}));});
  await submit();
  assert.equal(ricevuti.length,1);assert.equal(ricevuti[0].get('verificata'),'on');
  assert.equal(resetCount,0);assert.equal(check.checked,true);
  assert.equal(document.querySelector('[name=pdf]'),file);
  assert.match(document.querySelector('[role=status]').textContent,/Destinatario discordante/);
  esito={ok:true,messaggio:'Pro-forma registrata: ordine pronto per la fatturazione.'};
  await submit();
  assert.equal(ricevuti.length,2);assert.equal(resetCount,1);assert.equal(check.checked,false);
  assert.match(document.querySelector('[role=status]').textContent,/Pro-forma registrata/);
});
