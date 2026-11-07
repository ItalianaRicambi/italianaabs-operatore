import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getOperatoreAttivo } from '../operatore';
import { BarraOperatore } from '../components/IdentitaOperatore';
import { clientFic, ficConfigurato, messaggioErroreFic } from '../lib/fattureInCloudServer';
import { TIPI_FIC, validaRicercaFic, type RisultatoFic } from '../lib/fattureInCloud';

export const dynamic = 'force-dynamic';
export const maxDuration = 60;
const input = 'mt-1 block w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-slate-950';
function importo(value: number | null, valuta: string) {
  if (value === null) return 'Non disponibile';
  return `${new Intl.NumberFormat('it-IT', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(value)} ${valuta}`;
}
const STATI_PAGAMENTO: Record<string, string> = { paid: 'Pagato', not_paid: 'Non pagato', reversed: 'Stornato' };
export default async function FattureInCloud({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const operatore = await getOperatoreAttivo(); if (!operatore) redirect('/');
  const q = await searchParams;
  const singolo = (key: string, def = '') => typeof q[key] === 'string' ? q[key] as string : def;
  const oggi = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Rome', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date());
  const dal = singolo('dal', oggi.slice(0, 8) + '01'), al = singolo('al', oggi), tipo = singolo('tipo', 'invoice'), cerca = singolo('cerca');
  const configurato = ficConfigurato();
  let risultato: RisultatoFic | null = null, errore: string | null = null, azienda: string | null = null;
  if (configurato) {
    try {
      if (q.azione === 'verifica') azienda = (await clientFic().verifica()).nome;
      if (q.azione === 'cerca') risultato = await clientFic().cerca(validaRicercaFic({ tipo: q.tipo, dal: q.dal, al: q.al, cerca: q.cerca }));
    } catch (e) { errore = messaggioErroreFic(e); }
  }
  return <main className="min-h-screen bg-slate-50 text-slate-950">
    <BarraOperatore operatore={operatore} />
    <div className="mx-auto max-w-6xl px-4 py-8 sm:px-6">
      <Link href="/?filtro=area_amministrazione" prefetch={false} className="font-semibold text-blue-800 underline">← Amministrazione</Link>
      <div className="mb-6 mt-5 flex flex-wrap items-start justify-between gap-3">
        <div><p className="text-xs font-bold uppercase tracking-widest text-slate-500">Documenti aziendali</p>
          <h1 className="mt-2 text-3xl font-bold">Fatture in Cloud</h1>
          <p className="mt-2 text-slate-600">Consulta i documenti originali e i pagamenti registrati.</p></div>
        <span className="rounded-full bg-blue-100 px-3 py-1 text-sm font-bold text-blue-900">Sola lettura</span>
      </div>
      <p className="mb-5 rounded-xl border border-blue-200 bg-blue-50 p-4 text-sm text-blue-950">Questa consultazione non aggiorna le pratiche. La sincronizzazione automatica e il collegamento a ChatGPT sono ancora da attivare.</p>
      {!configurato ? <section className="rounded-xl border border-amber-300 bg-amber-50 p-5">
        <h2 className="font-bold text-amber-950">Completa il collegamento</h2>
        <p className="mt-2 text-sm">L’app è pronta per il test. Occorre inserire le credenziali nella configurazione protetta del server.</p>
        <p className="mt-2 text-sm">Il token non deve essere inserito nelle note delle pratiche o nella chat.</p>
      </section> : <>
        <form action="/fatture-in-cloud" method="get" className="mb-5 flex flex-wrap items-center gap-3">
          <button name="azione" value="verifica" className="rounded-lg border border-blue-300 bg-white px-4 py-2 font-semibold text-blue-900">Verifica accesso all’azienda</button>
          {azienda && <p role="status" className="text-sm font-semibold text-green-800">Accesso verificato: {azienda}. I permessi sui documenti saranno verificati dalla ricerca.</p>}
        </form>
        <form action="/fatture-in-cloud" method="get" className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <input type="hidden" name="azione" value="cerca" />
          <div className="grid gap-4 sm:grid-cols-3">
            <label className="text-sm font-semibold">Documento<select name="tipo" defaultValue={tipo} className={input}>{Object.entries(TIPI_FIC).map(([key, label]) => <option value={key} key={key}>{label}</option>)}</select></label>
            <label className="text-sm font-semibold">Dal<input type="date" name="dal" defaultValue={dal} required className={input} /></label>
            <label className="text-sm font-semibold">Al<input type="date" name="al" defaultValue={al} required className={input} /></label>
          </div>
          <label className="mt-4 block text-sm font-semibold">Cliente, targa, codice dispositivo o numero documento<input name="cerca" maxLength={100} defaultValue={cerca} placeholder="Es. AV41-2C405-AA oppure targa" className={input} /></label>
          <div className="mt-4 flex flex-wrap items-center justify-between gap-3"><p className="text-xs text-slate-600">Massimo 31 giorni per ricerca. Targhe e codici vengono cercati nei testi e nelle righe dei documenti.</p>
            <button className="rounded-lg bg-blue-800 px-5 py-2 font-bold text-white">Cerca documenti</button></div>
        </form>
      </>}
      {errore && <p role="alert" className="mt-5 rounded-xl border border-red-300 bg-red-50 p-4 text-red-900">{errore}</p>}
      {risultato && <section className="mt-6" aria-label="Risultati della ricerca">
        <h2 className="text-xl font-bold">{risultato.documenti.length} documenti trovati</h2>
        <p className="mt-1 text-sm text-slate-600">Esaminati {risultato.esaminati} di {risultato.totale} documenti del tipo e periodo selezionati. Verifica del {new Intl.DateTimeFormat('it-IT', { timeZone: 'Europe/Rome', dateStyle: 'short', timeStyle: 'short' }).format(new Date(risultato.verificatoAlle))}.</p>
        {!risultato.completo && <p role="alert" className="mt-3 rounded-lg bg-amber-100 p-4 font-semibold text-amber-950">Ricerca parziale: raggiunto il limite di 500 documenti. Riduci il periodo prima di concludere che un documento non è presente.</p>}
        {!risultato.documenti.length && <p className="mt-4 rounded-xl border bg-white p-5">{risultato.completo ? 'Nessuna corrispondenza nel tipo e periodo selezionati.' : 'Nessuna corrispondenza nei documenti esaminati finora.'}</p>}
        <div className="mt-4 space-y-4">{risultato.documenti.map(d => <article key={d.id} className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm">
          <div className="flex flex-wrap items-start justify-between gap-3"><div><h3 className="text-lg font-bold">{d.cliente}</h3><p className="mt-1 text-sm text-slate-600">{TIPI_FIC[d.tipo]} · n. {d.numero} · {d.data.split('-').reverse().join('/')}</p></div><p className="text-lg font-bold">{importo(d.importo, d.valuta)}</p></div>
          {d.oggetto && <p className="mt-3 whitespace-pre-wrap text-sm">{d.oggetto}</p>}
          <details className="mt-4 border-t border-slate-100 pt-3"><summary className="cursor-pointer text-sm font-bold text-blue-800">Righe, note e pagamenti</summary>
            <p className="mt-3 text-xs text-slate-500">ID Fatture in Cloud: {d.id} · P. IVA: {d.partitaIva || 'non indicata'} · C.F.: {d.codiceFiscale || 'non indicato'}</p>
            <ul className="mt-3 space-y-2">{d.righe.map((r, i) => <li key={i} className="rounded-lg bg-slate-50 p-3 text-sm"><strong>{r.codice} {r.nome}</strong><p className="mt-1 whitespace-pre-wrap">{r.descrizione}</p></li>)}</ul>
            {d.note && <p className="mt-3 whitespace-pre-wrap text-sm">{d.note}</p>}
            <h4 className="mt-4 text-sm font-bold">Pagamenti registrati nel documento</h4>
            {!d.pagamenti.length ? <p className="mt-1 text-sm text-slate-600">Nessun pagamento riportato.</p> : <ul className="mt-2 space-y-1 text-sm">{d.pagamenti.map((p, i) => <li key={i}>{importo(p.importo, d.valuta)} · scadenza {p.scadenza || 'non indicata'} · {STATI_PAGAMENTO[p.stato] || 'Stato non riconosciuto'}</li>)}</ul>}
            <p className="mt-3 text-xs text-slate-500">La presenza del documento o di un pagamento non conferma da sola la fatturazione di una pratica. Un proforma non è una fattura.</p>
          </details>
        </article>)}</div>
      </section>}
    </div>
  </main>;
}
