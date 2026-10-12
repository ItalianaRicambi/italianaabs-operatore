const assert = require('node:assert/strict');
const fs = require('node:fs');
const Module = require('node:module');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const { JSDOM } = require('jsdom');
const ts = require(root+'/node_modules/typescript');
const dom = new JSDOM('<!doctype html><main><div id="root"></div></main>', {url:'http://localhost'});
for (const name of ['window','document','HTMLElement','HTMLInputElement','HTMLSelectElement','HTMLFormElement','FormData','Event','MouseEvent']) global[name]=dom.window[name];
global.IS_REACT_ACT_ENVIRONMENT=true;
const React=require(root+'/node_modules/react');
const {createRoot}=require(root+'/node_modules/react-dom/client');
function load(file,mocks={}) {
  const filename=path.join(root,file);const m=new Module(filename,module);
  m.filename=filename;m.paths=Module._nodeModulePaths(path.dirname(filename));
  const original=m.require.bind(m);m.require=(name)=>name in mocks?mocks[name]:original(name);
  m._compile(ts.transpileModule(fs.readFileSync(filename,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,jsx:ts.JsxEmit.ReactJSX,target:ts.ScriptTarget.ES2020}}).outputText,filename);
  return m.exports;
}
const lib=load('app/lib/salvataggioDatiPratica.ts');
const {modificheNonSalvate,avviaControlloModifiche}=load('app/lib/modifichePratica.ts');
let handler;
const {DatiPraticaOperatore}=load('app/components/DatiPraticaOperatore.tsx',{
 '../lib/salvataggioDatiPratica':lib,
 '../pratica/[id]/actions':{salvaDatiPraticaOperatore: (...args)=>handler(...args)},
});
const initial={targa:'AA123BB',marca_veicolo:'Suzuki',modello_veicolo:'Vitara',tipo_componente:'ABS',tipo_guasto:'',descrizione_guasto:'Freno lungo'};
const rootReact=createRoot(document.getElementById('root'));
async function main(){
 await React.act(async()=>rootReact.render(React.createElement(DatiPraticaOperatore,{praticaId:'test',iniziali:initial})));
 const ferma=avviaControlloModifiche(document);
 assert.equal(modificheNonSalvate(),false);
 const select=document.querySelector('select');
 await React.act(async()=>{select.value='idraulico_meccanico';select.dispatchEvent(new Event('change',{bubbles:true}));});
 assert.equal(modificheNonSalvate(),true);
 let finish;
 handler=()=>new Promise(resolve=>{finish=resolve});
 await React.act(async()=>document.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true})));
 assert.equal(document.querySelector('button').disabled,true);
 assert.match(document.querySelector('button').textContent,/Salvataggio in corso/);
 await React.act(async()=>finish({ok:true,dati:{...initial,tipo_guasto:'idraulico_meccanico'},messaggio:'Dati salvati e confermati. Puoi tornare all’elenco.'}));
 assert.equal(document.querySelector('button').disabled,false);
 assert.equal(document.querySelector('select').value,'idraulico_meccanico');
 assert.match(document.querySelector('[role="status"]').textContent,/Dati salvati/);
 assert.equal(modificheNonSalvate(),false);
 await React.act(async()=>{select.value='elettrico_elettronico';select.dispatchEvent(new Event('change',{bubbles:true}));});
 assert.equal(modificheNonSalvate(),true);
 handler=async()=>({ok:false,messaggio:'Salvataggio non riuscito. Le modifiche restano nei campi.'});
 await React.act(async()=>document.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true})));
 assert.equal(document.querySelector('select').value,'elettrico_elettronico');
 assert.match(document.querySelector('[role="alert"]').textContent,/non riuscito/);
 assert.equal(modificheNonSalvate(),true);
 handler=async()=>{throw new Error('network disconnected')};
 await React.act(async()=>document.querySelector('form').dispatchEvent(new Event('submit',{bubbles:true,cancelable:true})));
 assert.match(document.querySelector('[role="alert"]').textContent,/Connessione interrotta/);
 assert.equal(document.querySelector('select').value,'elettrico_elettronico');
 assert.equal(modificheNonSalvate(),true);
 const other=document.createElement('form');other.innerHTML='<input value="iniziale">';document.querySelector('main').append(other);await Promise.resolve();
 document.querySelector('form').setAttribute('data-modifiche-non-salvate','false');
 assert.equal(modificheNonSalvate(),false);
 other.querySelector('input').value='cambiato';other.querySelector('input').dispatchEvent(new Event('input',{bubbles:true}));assert.equal(modificheNonSalvate(),true);
 ferma();await React.act(async()=>rootReact.unmount());
 console.log('UI verificata: pending, conferma visibile, selezione conservata, uscita dopo salvataggio, errore senza perdita dati, protezione delle altre form.');
}
main().catch(e=>{console.error(e);process.exitCode=1});
