// PostgreSQL isolato, solo dati sintetici. Nessuna connessione di produzione.
// PGLITE_MODULE può indicare il modulo PGlite installato esternamente al progetto.
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const { PGlite } = await import(process.env.PGLITE_MODULE || '@electric-sql/pglite');
const db = new PGlite();
const read = name => readFile(new URL('../supabase/migrations/'+name,import.meta.url),'utf8');
const p='10000000-0000-4000-8000-000000000001', p2='10000000-0000-4000-8000-000000000002';
const s='20000000-0000-4000-8000-000000000001', s2='20000000-0000-4000-8000-000000000002';
let checks=0;
async function check(sql,expected){const r=await db.query(sql);assert.deepEqual(r.rows[0].v,expected,sql);checks++;}
async function original(id,text,session=s,extra={}) {
 await db.query(`insert into public.keplero_originali(sessione,messaggio_id,testo,direzione,tipo,candidato,modificato,revoca,data_messaggio)
 values($1,$2,$3,$4,'text',false,false,false,coalesce($5::timestamptz,now()))`,
 [session,id,text,extra.direction||'entrata',extra.date||null]);
}
try {
 await db.exec(`create schema private;create role anon;create role authenticated;create role service_role;
 create table public.pratiche(id uuid primary key,numero_pratica integer,targa text,stato_commerciale text,
 tipo_flusso text default 'commerciale',blocco_operatore boolean default false,
 blocco_classificazione_operatore boolean default true,dati_raw jsonb default '{}');
 create table public.keplero_live_events(id bigint primary key,pratica_id uuid,payload jsonb,created_at timestamptz default now());
 create table public.keplero_originali(sessione uuid,messaggio_id text,testo text,direzione text,tipo text,
 candidato boolean,modificato boolean,revoca boolean,data_messaggio timestamptz,primary key(sessione,messaggio_id));
 create table public.keplero_verifiche_originali(sessione uuid,messaggio_id text,esito text,operatore text);
 create table public.keplero_pratiche_conversazioni(sessione uuid,pratica_id uuid,primary key(sessione,pratica_id));`);
 const window=await read('20261001213823_sospendi_finestra_controllo_weekend.sql');
 await db.exec(window.slice(0,window.indexOf('create or replace function private.candidati_coerenza_keplero')));
 const baseline=await read('20261116173719_coda_evasione_ordini.sql');
 await db.exec(baseline.slice(baseline.indexOf('create table public.verifiche_acquisizione_ordini'),baseline.indexOf('create function public.risolvi_verifica_acquisizione')));
 await db.exec(baseline.slice(baseline.indexOf('create view public.v_verifiche_acquisizione_ordini'),baseline.indexOf('-- Risolve soltanto')));
 await db.query(`insert into public.pratiche(id,numero_pratica,targa,stato_commerciale) values($1,1,'TEST001','raccolta_dati'),($2,2,'TEST002','raccolta_dati')`,[p,p2]);
 await db.query('insert into public.keplero_pratiche_conversazioni values($1,$2)',[s,p]);
 const accepted="Confermo l'offerta per la lavorazione della centralina ABS";
 await original('1',accepted);
 const before=(await db.query('select * from public.pratiche order by id')).rows;
 await db.exec(await read('20261117085731_conferme_originali_dashboard.sql'));
 await db.exec(await read('20261117094805_conferme_contestuali_coda_verifica.sql'));
 await check('select count(*)::int v from public.v_verifiche_acquisizione_ordini',1);
 await check('select evento_id is null and originale_messaggio_id=\'1\' and blocco_classificazione_operatore v from public.v_verifiche_acquisizione_ordini',true);
 await db.query('update public.keplero_originali set candidato=false where messaggio_id=$1',['1']);
 await check('select count(*)::int v from public.verifiche_acquisizione_ordini',1);
 await db.query('insert into public.keplero_live_events values(1,$1,$2,now())',[p,{ultimo_messaggio_cliente:accepted}]);
 await check('select count(*)::int v from public.verifiche_acquisizione_ordini',1);
 for(const [i,t] of ['Non confermo il preventivo','Confermo il bonifico','Quando passa il corriere?',
  'Programma scambio','Confermerei il preventivo','Confermo il preventivo?'].entries()) await original('no'+i,t);
 await original('out','Accettiamo il preventivo',s,{direction:'uscita'});
 await original('old','Approviamo il preventivo',s,{date:'2020-01-01T00:00:00Z'});
 await check('select count(*)::int v from public.verifiche_acquisizione_ordini',1);
 for(const [i,t] of ['Accetto il preventivo','Accettiamo il preventivo','Confermiamo la lavorazione',
  'Approvo il preventivo','Approviamo il preventivo'].entries()) await original('yes'+i,t);
 await check('select count(*)::int v from public.v_verifiche_acquisizione_ordini',6);
 await original('late','Confermo il preventivo',s2);
 await check('select count(*)::int v from public.v_verifiche_acquisizione_ordini',6);
 await db.query('insert into public.keplero_pratiche_conversazioni values($1,$2)',[s2,p2]);
 await check('select count(*)::int v from public.v_verifiche_acquisizione_ordini',7);
 await original('cancel','Annullo il preventivo',s);
 await db.exec("update public.keplero_originali set data_messaggio=now()+interval '1 second' where messaggio_id='cancel'");
 await check(`select bool_and(possibile_revoca) v from public.v_verifiche_acquisizione_ordini where pratica_id='${p}'`,true);
 await db.exec("update public.keplero_originali set modificato=true where messaggio_id='1'");
 await check("select prova_modificata v from public.v_verifiche_acquisizione_ordini where originale_messaggio_id='1'",true);
 await db.query('insert into public.keplero_pratiche_conversazioni values($1,$2)',[s,p2]);
 await original('ambiguous','Confermo la riparazione ABS');
 await check('select count(*)::int v from public.verifiche_acquisizione_ordini',7);
 await check(`select bool_and(collegamento_da_verificare) v from public.v_verifiche_acquisizione_ordini where pratica_id='${p}'`,true);
 assert.deepEqual((await db.query('select * from public.pratiche order by id')).rows,before);checks++;
 await db.exec("update public.verifiche_acquisizione_ordini set risolta_at=now() where originale_messaggio_id='1'");
 await db.exec("update public.keplero_originali set candidato=false where messaggio_id='1'");
 await check('select count(*)::int v from public.v_verifiche_acquisizione_ordini',6);
 await db.exec("insert into public.keplero_verifiche_originali values('"+s2+"','late','archiviata','Operatore 1')");
 await check('select count(*)::int v from public.v_verifiche_acquisizione_ordini',5);
 for(const stato of ['ordine_acquisito','rifiutato','chiuso']) {
  await db.query('update public.pratiche set stato_commerciale=$1 where id=$2',[stato,p]);
  await check('select count(*)::int v from public.v_verifiche_acquisizione_ordini',0);
 }
 await check("select has_table_privilege('anon','public.v_verifiche_acquisizione_ordini','select') v",false);
 await check("select has_function_privilege('authenticated','private.accoda_verifica_originale_ordine(uuid,text)','execute') v",false);
 for (const [t,want] of [
  ['Ok facciamo quello originale della macchina\nQuando lo potete ritirare?',true],
  ['Confermo il preventivo. Quando passa il corriere?',true],
  ['Accettiamo la lavorazione. Quando spediamo?',true],
  ['Scelgo il programma scambio',true],
  ['Procediamo con la riparazione',true],
  ['Confermo il preventivo?',false],
  ['Facciamo quello originale?',false],
  ['Vorrei confermare il preventivo',false],
  ['Vorremmo confermare il preventivo',false],
  ['Non confermo il preventivo. Quando passa il corriere?',false],
  ['Confermo il bonifico. Quando spediamo?',false],
  ['Programma scambio',false],
  ['Se scelgo il programma scambio quanto costa?',false],
  ['Confermo il preventivo. Annulliamo tutto.',false],
 ]) {
  const r=await db.query('select private.conferma_contestuale_da_verificare($1) v',[t]);
  assert.equal(r.rows[0].v,want,t);checks++;
 }
 await db.query('delete from public.keplero_pratiche_conversazioni where sessione=$1 and pratica_id=$2',[s,p2]);
 await db.query("update public.pratiche set stato_commerciale='preventivo_inviato' where id=$1",[p]);
 const protectedBefore=(await db.query('select * from public.pratiche order by id')).rows;
 await original('choice','Ok facciamo quello originale della macchina\nQuando lo potete ritirare?');
 await check("select count(*)::int v from public.v_verifiche_acquisizione_ordini where originale_messaggio_id='choice'",1);
 await db.query('insert into public.keplero_live_events values(2,$1,$2,now())',[p,{ultimo_messaggio_cliente:'Confermo il preventivo. Quando passa il corriere?'}]);
 await check('select count(*)::int v from public.v_verifiche_acquisizione_ordini where evento_id=2',1);
 await db.query('insert into public.keplero_live_events values(3,$1,$2,$3)',[p,{ultimo_messaggio_cliente:'Scelgo il programma scambio'},'2020-01-01']);
 await check('select count(*)::int v from public.verifiche_acquisizione_ordini where evento_id=3',0);
 assert.deepEqual((await db.query('select * from public.pratiche order by id')).rows,protectedBefore);checks++;
 await check("select has_function_privilege('anon','private.conferma_contestuale_da_verificare(text)','execute') v",false);
 console.log(`PASS PostgreSQL isolato: ${checks} verifiche + 10 casi weekend/DST. Nessuna pratica modificata dall'accodamento.`);
} finally { await db.close(); }
