import Link from 'next/link';
import { avvisoOrdine } from '../lib/avvisiOrdini';
import type { PraticaOggi } from '../lib/oggi';

export function AvvisoOrdine({ pratica }: { pratica: PraticaOggi }) {
  const a = avvisoOrdine(pratica);
  if (!a) return null;
  return <section role="alert" className={`mb-5 rounded-2xl border-2 p-5 shadow-sm ${a.pronto ? 'border-red-700 bg-red-50 text-red-950' : 'border-amber-600 bg-amber-50 text-amber-950'}`}>
    <p className="text-lg font-black">⚠ {a.titolo}</p>
    <p className="mt-2 text-sm font-medium">{a.testo}</p>
    <Link href={`/pratica/${pratica.id}#sezione-amministrazione`} prefetch={false} className="mt-4 inline-flex min-h-11 items-center rounded-lg bg-slate-950 px-4 py-2 font-bold text-white">Apri fatturazione e dati cliente →</Link>
    <p className="mt-3 text-xs">L’avviso si chiude quando la fattura della pratica è verificata. Ritiri, lavorazione e spedizione mantengono il proprio avanzamento.</p>
  </section>;
}

export function AvvisiOrdini({ pratiche }: { pratiche: PraticaOggi[] }) {
  const ordini = pratiche.filter(p => avvisoOrdine(p));
  if (!ordini.length) return null;
  const pronti = ordini.filter(p => avvisoOrdine(p)?.pronto).length;
  return <section role="alert" className="mb-6 rounded-2xl border-2 border-red-700 bg-red-50 p-5 text-red-950 shadow-sm">
    <p className="text-xl font-black">⚠ {ordini.length} ORDINI ACCETTATI DA GESTIRE</p>
    <p className="mt-2 font-semibold">{pronti} pronti da fatturare · {ordini.length - pronti} con controllo anagrafica o dati da completare</p>
    <p className="mt-1 text-sm">Emettere fattura e organizzare le attività della pratica. L’avviso resta visibile fino alla verifica della fattura.</p>
    <div className="mt-3 flex flex-wrap gap-2">{ordini.slice(0,5).map(p => <Link key={p.id} href={`/pratica/${p.id}#sezione-amministrazione`} prefetch={false} className="rounded-lg border border-red-300 bg-white px-3 py-2 text-sm font-bold">{p.targa || p.codice_pratica} · {p.nome_cliente || 'Cliente da identificare'} →</Link>)}</div>
    <Link href="/?filtro=ordini_confermati" prefetch={false} className="mt-4 inline-flex rounded-lg bg-red-800 px-4 py-3 font-bold text-white">Vedi tutti gli ordini da gestire →</Link>
  </section>;
}
