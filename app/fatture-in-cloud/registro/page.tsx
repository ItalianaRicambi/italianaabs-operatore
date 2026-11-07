import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getOperatoreAttivo } from '../../operatore';
import { BarraOperatore } from '../../components/IdentitaOperatore';
import { leggiRegistroFic, pratichePerFic } from '../../lib/ficRegistroServer';
import { abbinaFic } from '../../lib/abbinamentiFic';
import { TIPI_FIC } from '../../lib/fattureInCloud';
import FormSincronizza from './FormSincronizza';
export const dynamic = 'force-dynamic';
export const maxDuration = 120;
export default async function Registro() {
  const operatore = await getOperatoreAttivo(); if(!operatore) redirect('/');
  const oggi = new Intl.DateTimeFormat('en-CA',{timeZone:'Europe/Rome',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
  let errore = '', righe: Awaited<ReturnType<typeof leggiRegistroFic>> = [], pratiche: Awaited<ReturnType<typeof pratichePerFic>> = [];
  try { [righe,pratiche] = await Promise.all([leggiRegistroFic(),pratichePerFic()]); }
  catch { errore = 'Registro o pratiche non disponibili. Nessun abbinamento verificato.'; }
  return <main className="min-h-screen bg-slate-50 text-slate-950"><BarraOperatore operatore={operatore}/><div className="mx-auto max-w-6xl px-5 py-8">
    <Link href="/fatture-in-cloud" className="font-bold text-blue-800 underline">← Consultazione Fatture in Cloud</Link>
    <h1 className="mt-5 text-3xl font-bold">Registro documenti e pratiche</h1>
    <p className="mt-2 text-slate-600">Documenti acquisiti e possibili corrispondenze. Fatture e proforma rimangono distinti; la verifica di una proposta va completata nella scheda pratica.</p>
    <FormSincronizza oggi={oggi}/>
    {errore?<p role="alert" className="rounded border border-red-300 bg-red-50 p-4">{errore}</p>:<>
      <p className="mb-4 text-sm">Ultimi {righe.length} documenti acquisiti (massimo 100). La data di verifica indica l’ultimo controllo del periodo.</p>
      {!righe.length&&<p className="rounded border bg-white p-5">Il registro è vuoto. Seleziona un tipo di documento e sincronizza il periodo.</p>}
      <div className="space-y-4">{righe.map(r=>{const d=r.documento,a=abbinaFic(d,pratiche);return <article key={r.documento_id} className="rounded-xl border bg-white p-5">
        <h2 className="font-bold">{TIPI_FIC[d.tipo]} {d.numero} · {d.data} · {d.cliente}</h2>
        <p className="mt-1 text-sm text-slate-600">ID {d.id} · ultima verifica {new Date(r.verificato_at).toLocaleString('it-IT',{timeZone:'Europe/Rome'})}</p>
        {!r.presente?<p className="mt-3 font-semibold text-amber-900">Non più rilevato nel periodo: potrebbe essere stato modificato o eliminato. Ricontrollare l’originale.</p>:<>
          <p className="mt-3 text-sm">{a.motivo}</p>
          <ul className="mt-2 space-y-1">{a.candidati.map(p=><li key={p.id}><Link href={`/pratica/${p.id}`} prefetch={false} className="font-bold text-blue-800 underline">Pratica {p.numero_pratica} · {p.targa} · {p.nome_cliente}</Link></li>)}</ul>
        </>}
      </article>;})}</div>
    </>}
  </div></main>;
}
