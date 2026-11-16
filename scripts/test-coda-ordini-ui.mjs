// Local-only integration test. Synthetic orders, credentials and session; no production writes.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { createHmac } from 'node:crypto';
import { createRequire } from 'node:module';
import assert from 'node:assert/strict';
const require = createRequire(import.meta.url);
const secret = 'local-only-order-flow-test-secret-0123456789';
let fail = false; const writes=[];
const pratica = {pratica_id:'10000000-0000-4000-8000-000000000001',numero_pratica:999001,targa:'TEST001',
 stato:'da_evadere',revisione:1,nota:'Ordine locale di collaudo',updated_at:'2026-11-16T00:00:00Z',
 stato_fatturazione:'fatturato',shopify_order_id:null,blocco_operatore:false};
const ordine={id:'s1',pratica_id:null,conflitto:false,ricevuto_at:'2026-11-16T00:00:00Z',valutazione:{},dati:{
 ordine_id:'999001',numero:'#TEST1',shop:'j4mqgv-am.myshopify.com',test:false,annullato:false,stato_pagamento:'paid',
 stato_evasione:'da_evadere',servizi:['RI'],articoli:[{titolo:'Dispositivo di collaudo',variante:'RI',quantita:1}],
 iva:100,esente_shopify:false,spedizione:{paese:'IT'},tipo_cliente:'non_dichiarato'}};
const verifica={id:'20000000-0000-4000-8000-000000000001',pratica_id:pratica.pratica_id,
 numero_pratica:999002,targa:'TEST002',evento_id:99999,evento_at:'2026-11-16T11:00:00Z',
 messaggio:'Ordine fatto',stato_commerciale:'preventivo_inviato',blocco_operatore:true,possibile_revoca:true};
const mock=createServer(async(req,res)=>{
 res.setHeader('Content-Type','application/json');
 if(req.method==='POST'){
  if(req.url.endsWith('/stato_sync_shopify')) {res.end(JSON.stringify({ultimo_successo_at:null,errore:null,ordini_letti:0}));return;}
  let body='';for await(const c of req)body+=c;
  writes.push({url:req.url,body:JSON.parse(body)});
  res.end('true');return;
 }
 if(fail && req.url.includes('v_evasioni_pratiche')){res.statusCode=503;res.end('{}');return;}
 const rows=req.url.includes('/ordini_shopify?')?[ordine]:req.url.includes('/v_evasioni_pratiche?')?[pratica]:
 req.url.includes('/v_verifiche_acquisizione_ordini?')?[verifica]:[];
 res.setHeader('Content-Range',rows.length?'0-0/1':'*/0');res.end(JSON.stringify(rows));
});
console.log('Starting isolated test services');
await new Promise(r=>mock.listen(0,'127.0.0.1',r));
const mockUrl='http://127.0.0.1:'+mock.address().port;
const probe=createServer();await new Promise(r=>probe.listen(0,'127.0.0.1',r));
const port=probe.address().port;await new Promise(r=>probe.close(r));
const base='http://127.0.0.1:'+port;
const child=spawn(process.execPath,['node_modules/next/dist/bin/next','start','-H','127.0.0.1','-p',String(port)],{
 env:{...process.env,SUPABASE_URL:mockUrl,SUPABASE_SECRET_KEY:'synthetic-test-only',
 OPERATORE_SESSION_SECRET:secret},stdio:['ignore','pipe','pipe']});
let logs='';child.stdout.on('data',d=>logs+=d);child.stderr.on('data',d=>logs+=d);
let browser;
const deadline=setTimeout(()=>{console.error('Test timeout',logs.slice(-2000));child.kill('SIGTERM');mock.closeAllConnections();process.exitCode=1;},60000);
try{
 for(let i=0;i<30;i++){try{await fetch(base+'/ordini',{redirect:'manual',signal:AbortSignal.timeout(1000)});break;}catch{await new Promise(r=>setTimeout(r,250));}}
 console.log('Test server ready',logs.slice(-500));
 const unauth=await fetch(base+'/ordini',{redirect:'manual',signal:AbortSignal.timeout(5000)});
 assert.equal(unauth.status,307);
 const signature=createHmac('sha256',secret).update('italianaabs:1').digest('base64url');
 if(process.env.ORDER_FLOW_SSR_ONLY==='1') {
  const headers={cookie:'italianaabs_operatore=1.'+signature};
  const response=await fetch(base+'/ordini',{headers,signal:AbortSignal.timeout(10000)});
  assert.equal(response.status,200);const html=await response.text();
  for(const value of ['#TEST1','TEST001','fatturato','Pratica non collegata','Possibile revoca successiva','Ordine fatto']) assert.ok(html.includes(value),value);
  assert.ok(html.includes('Lettura API Shopify non ancora collaudata.'));
  fail=true;const errore=await (await fetch(base+'/ordini',{headers,signal:AbortSignal.timeout(10000)})).text();
  assert.ok(errore.includes('Dati incompleti:'));assert.equal(writes.length,0);
  console.log('PASS HTTP/SSR: accesso protetto, Shopify orfano, fattura indipendente, prove/revoca e errore di lettura esplicito. Nessuna azione eseguita.');
 } else {
 const { chromium } = require('playwright');
 browser=await chromium.launch({headless:true,executablePath:process.env.ORDER_FLOW_CHROMIUM || undefined});
 const context=await browser.newContext({viewport:{width:1280,height:900}});
 await context.addCookies([{name:'italianaabs_operatore',value:'1.'+signature,url:base}]);
 const page=await context.newPage();await page.goto(base+'/ordini');
 await page.getByRole('heading',{name:'Shopify da evadere (1)',exact:true}).waitFor();
 assert.equal(await page.getByText('Pratica non collegata: l’ordine resta comunque visibile e da gestire.').count(),1);
 assert.equal(await page.getByText('Evasione: da_evadere · Fatturazione: fatturato').count(),1);
 assert.equal(await page.getByText('Possibile revoca successiva:',{exact:false}).count(),1);
 await page.getByText('Aggiorna evasione con prova',{exact:true}).click();
 await page.locator('select[name=stato]').selectOption('evaso');
 await page.locator('textarea[name=nota]').first().fill('Collaudo locale, nessuna spedizione reale.');
 await page.getByRole('button',{name:'Conferma manualmente'}).first().click();
 await page.getByRole('status').filter({hasText:'Registrato nello storico operatore.'}).waitFor();
 assert.equal(writes.length,1);assert.equal(writes[0].body.p_revisione,1);
 assert.equal(writes[0].body.p_operatore,'Operatore 1');
 fail=true;await page.reload();
 await page.getByRole('alert').filter({hasText:'Dati incompleti:'}).waitFor();
 await page.setViewportSize({width:390,height:844});
 assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'Mobile overflow');
 console.log('PASS UI: accesso protetto, Shopify orfano, fattura indipendente, revoca, azione autenticata, errore esplicito, mobile.');
 }
}catch(e){console.error(logs.slice(-3000));throw e;}
finally{clearTimeout(deadline);if(browser)await browser.close();child.kill('SIGTERM');mock.closeAllConnections();await new Promise(r=>mock.close(r));}
