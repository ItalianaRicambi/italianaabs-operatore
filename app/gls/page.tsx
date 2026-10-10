import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getOperatoreAttivo } from '../operatore';
import { BarraOperatore } from '../components/IdentitaOperatore';
import { ImportazioneGls, AbbinamentoEsitoGls } from '../components/ImportazioneGls';
import { EsitoGlsCard } from '../components/EsitiGls';
import { connessioneGlsDb, leggiEsitiGls } from '../lib/glsServer';
import { fetchTutteLePagine } from '../lib/supabaseRest';
import { NOMI_RITIRO } from '../lib/flussiOperativi';
import { NOMI_ESITO_GLS, statoGlsAttuale } from '../lib/esitiGls';

export default async function MonitoraggioGls({ searchParams }: { searchParams: Promise<{ stato?: string }> }) {
 const operatore = await getOperatoreAttivo(); if (!operatore) redirect('/');
 const [{ righe, errore }, params] = await Promise.all([leggiEsitiGls(), searchParams]);
 let ritiri: { id: string; label: string }[] = [], erroreRitiri = false;
 if (righe.some(e => e.esito_abbinamento !== 'abbinata')) {
  try {
   const { url, headers } = connessioneGlsDb();
   const a = await fetchTutteLePagine<{ id: string; tipo: string; codice_pratica: string; nome_cliente: string; targa: string }>(`${url}/rest/v1/v_attivita_operatore_aperte?tipo=like.ritiro_%25&select=id,tipo,codice_pratica,nome_cliente,targa&order=richiesta_at.asc,id.asc`, { headers });
   ritiri = a.map(e => ({ id: e.id, label: `${e.codice_pratica} · ${e.nome_cliente || ''} · ${e.targa || ''} · ${NOMI_RITIRO[e.tipo] || e.tipo}` }));
  } catch { erroreRitiri = true; }
 }
 const stati = { tutte: 'Tutte le prese', ...NOMI_ESITO_GLS, da_abbinare: 'Abbinamenti da verificare' };
 const filtro = params.stato && params.stato in stati ? params.stato : 'tutte';
 const filtrate = righe.filter(e => filtro === 'tutte' || (filtro === 'da_abbinare' ? e.esito_abbinamento !== 'abbinata' : statoGlsAttuale(e) === filtro));
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={operatore} /><div className="mx-auto max-w-6xl px-6 py-8">
  <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link>
  <h1 className="mt-4 text-3xl font-bold">Monitoraggio prese GLS</h1>
  <p className="mt-2 text-sm text-slate-600">Stati del corriere e motivazioni, collegati al singolo ritiro per lavorazione, garanzia o reso.</p>
  <div className="my-5 rounded-xl border border-amber-300 bg-amber-50 p-4 text-sm text-amber-950"><strong>Aggiornamento automatico GLS da configurare.</strong> Questi sono gli esiti dei controlli registrati, con data e ora. Il solo accesso al portale non attiva una sincronizzazione continua.</div>
  <details className="mb-5 rounded-xl border border-slate-200 bg-white p-4 text-sm"><summary className="cursor-pointer font-bold">Destinazioni dei ritiri</summary>
   <ul className="mt-3 list-disc space-y-1 pl-5"><li>ALB Meccatronica: lavorazioni auto.</li><li>Judmax: lavorazioni moto.</li><li>Monika Bednarska, Germania: Audi/VW 01130 e ABS ATE Freemont/Dodge C2200.</li><li>Italiana Ricambi: principalmente rientri Programma Scambio, storni ordine e altri resi.</li></ul>
   <p className="mt-3">La destinazione è un indizio: il motivo del rientro resta quello verificato nella pratica. “Ritiro preso in carico” e “Non effettuato” nell’elenco delle prese future non provano il ritiro fisico o un tentativo fallito.</p>
  </details>
  <ImportazioneGls />
  {errore && <p className="mb-4 text-red-800">{errore}</p>}
  <nav aria-label="Filtra esiti GLS" className="mb-5 flex flex-wrap gap-2">{Object.entries(stati).map(([key, label]) => <Link key={key} href={key === 'tutte' ? '/gls' : `/gls?stato=${key}`} className={`rounded-lg border px-3 py-2 text-sm font-semibold ${filtro === key ? 'border-blue-700 bg-blue-700 text-white' : 'border-slate-300 bg-white text-slate-800'}`}>{label} ({righe.filter(e => key === 'tutte' || (key === 'da_abbinare' ? e.esito_abbinamento !== 'abbinata' : statoGlsAttuale(e) === key)).length})</Link>)}</nav>
  {!errore && !filtrate.length && <p className="rounded-xl border border-slate-200 bg-white p-5">Nessun esito registrato in questa categoria.</p>}
  <div className="space-y-4">{filtrate.map(e => <section key={e.id}><EsitoGlsCard esito={e} />
   {e.esito_abbinamento !== 'abbinata' && <details className="mt-2 rounded-xl border border-amber-200 bg-white p-4"><summary className="cursor-pointer font-bold text-amber-950">Verifica il collegamento alla pratica</summary>
    {erroreRitiri ? <p className="mt-2 text-red-800">Elenco dei ritiri non disponibile. Riprova prima di confermare.</p> : <AbbinamentoEsitoGls esitoId={e.id} ritiri={ritiri} />}
   </details>}
  </section>)}</div>
 </div></main>;
}
