// Dopo npm run build: SSR reale, Supabase simulato e sessione di test isolata.
const http = require('node:http');
const { spawn } = require('node:child_process');
const { createHmac } = require('node:crypto');
const assert = require('node:assert/strict');
const nativeFetch=fetch; global.fetch=(url,options={})=>nativeFetch(url,{...options,signal:AbortSignal.timeout(4000)});
const p = '10000000-0000-4000-8000-000000000001';
const a = '10000000-0000-4000-8000-000000000002';
const secret = 'test-prenotazioni-session-secret-000000000';
const pratica = {id:p,numero_pratica:1,codice_pratica:'ABS-000001',created_at:new Date().toISOString(),targa:'TST001A',nome_cliente:'Fixture prese',tipo_flusso:'commerciale',stato_assistenza:'non_applicabile',stato_completezza:'dati_mancanti',stato_commerciale:'ordine_acquisito',stato_fatturazione:'non_applicabile',stato_followup:'non_previsto',stato_logistica:'ritiro_programmato',coda:'ORDINE ACQUISITO',priorita:3,dati_raw:{},campi_bloccati_operatore:[],campi_richiesta_amministrativa:[]};
const activity = {id:a,pratica_id:p,pratica_origine_id:p,codice_pratica_origine:'ABS-000001',tipo:'ritiro_lavorazione',stato:'programmata',priorita:'alta',evidenza:'Presa verificata',richiesta_at:new Date().toISOString(),riferimento_ritiro:'P3 9260993058',data_ritiro_prevista:'2026-10-12',metadati:{prenotazione_fonte:'email_gls'}};
const pending = {id:'10000000-0000-4000-8000-000000000003',pratica_id:null,esito:'abbinamento_ambiguo',riferimento:'P3 9260993999',data_ritiro:'2026-10-13',testo:'Conferma GLS da abbinare',errore:null};
let app, output = '';
const db = http.createServer((req,res) => {
  const u=new URL(req.url,'http://localhost'); const table=u.pathname.split('/').pop();
  let rows=table==='pratiche'||table==='v_coda_operatore_tempi'?[pratica]:table==='v_attivita_operatore_aperte'?[activity]:table==='prenotazioni_prese_ricevute'?[pending]:table==='keplero_controllo_stato'?[{id:1,ultima_esecuzione_at:new Date().toISOString(),segnalazioni_aperte:0,eventi_esaminati:1,risposte_k_disponibili:false}]:[];
  const select=u.searchParams.get('select');
  if(select&&select!=='*')rows=rows.map(r=>Object.fromEntries(select.split(',').map(k=>[k,r[k]])));
  res.writeHead(200,{'Content-Type':'application/json','content-range':`0-${Math.max(rows.length-1,0)}/${rows.length}`}); res.end(JSON.stringify(rows));
});
(async () => {
  await new Promise(resolve=>db.listen(0,'127.0.0.1',resolve));
  const url=`http://127.0.0.1:${db.address().port}`;
  app=spawn(process.execPath,['node_modules/next/dist/bin/next','start','--hostname','127.0.0.1','--port','3192'],{cwd:process.cwd(),env:{...process.env,SUPABASE_URL:url,NEXT_PUBLIC_SUPABASE_URL:url,SUPABASE_SECRET_KEY:'test-only',SUPABASE_SERVICE_ROLE_KEY:'test-only',OPERATORE_SESSION_SECRET:secret},stdio:['ignore','pipe','pipe']});
  app.stdout.on('data',s=>{output+=s;process.stdout.write(s);});app.stderr.on('data',s=>{output+=s;process.stderr.write(s);});
  app.on('error',e=>{console.error(e);});
  const cookie=`italianaabs_operatore=1.${createHmac('sha256',secret).update('italianaabs:1').digest('base64url')}`;
  let ready=false;
  for(let i=0;i<10;i++){try{await fetch('http://127.0.0.1:3192');ready=true;break;}catch{await new Promise(r=>setTimeout(r,200));}}
  assert.ok(ready,'App non avviata');
  const dashboard=await fetch('http://127.0.0.1:3192/?filtro=prese_prenotate',{headers:{cookie}});
  const html=await dashboard.text();assert.equal(dashboard.status,200,output);
  for(const text of ['Prese prenotate','P3 9260993058','12/10/2026','Conferme prese da verificare','P3 9260993999','Conferma abbinamento e prenotazione','ABS-000001'])assert.ok(html.includes(text),`Dashboard manca ${text}`);
  const detail=await fetch(`http://127.0.0.1:3192/pratica/${p}`,{headers:{cookie}});const body=await detail.text();assert.equal(detail.status,200,output);
  for(const text of ['Presa prenotata','P3 9260993058','12/10/2026','Leggi data e codice','Conferma presa prenotata'])assert.ok(body.includes(text),`Scheda manca ${text}; ${output}`);
  assert.ok(!body.includes('name="azione" value="logistica_ritiro_programmato"'),'Azione logistica storica visibile sul ritiro corrente');
  assert.ok(!html.includes('Impossibile leggere le conferme delle prese'));
  console.log('PASS: filtro e dati prenotazione, coda ambigua, scheda e separazione logistica storica (HTTP 200).');
})().catch(e=>{console.error(e);process.exitCode=1;}).finally(()=>{app?.kill('SIGTERM');db.close();});
