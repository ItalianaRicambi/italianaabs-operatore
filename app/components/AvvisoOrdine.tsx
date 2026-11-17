import Link from 'next/link';
import { randomUUID } from 'node:crypto';
import { ApriPraticaConContesto, ContestoNavigazioneElenco } from './NavigazionePratiche';
import { avvisoOrdine } from '../lib/avvisiOrdini';
import type { PraticaOggi } from '../lib/oggi';

export function AvvisoOrdine({ pratica }: { pratica: PraticaOggi }) {
  const a = avvisoOrdine(pratica);
  if (!a) return null;
  return <section role="alert" className={`mb-5 rounded-2xl border-2 p-5 shadow-sm ${a.pronto ? 'border-red-700 bg-red-50 text-red-950' : 'border-amber-600 bg-amber-50 text-amber-950'}`}>
    <p className="text-lg font-black">⚠ {a.titolo}</p>
    <p className="mt-2 text-sm font-medium">{a.testo}</p>
    <Link href="#sezione-amministrazione" prefetch={false} className="mt-4 inline-flex min-h-11 items-center rounded-lg bg-slate-950 px-4 py-2 font-bold text-white">Apri fatturazione e dati cliente →</Link>
    <p className="mt-3 text-xs">L’avviso si chiude quando la fattura della pratica è verificata. Ritiri, lavorazione e spedizione mantengono il proprio avanzamento.</p>
  </section>;
}

export function AvvisiOrdini({ pratiche }: { pratiche: PraticaOggi[] }) {
  const ordini = pratiche.filter(p => avvisoOrdine(p));
  if (!ordini.length) return null;
  const pronti = ordini.filter(p => avvisoOrdine(p)?.pronto).length;
  return <ContestoNavigazioneElenco chiave={randomUUID()} filtro="ordini_confermati" etichetta="Ordini da fatturare" cerca=""
    ritorno="/?filtro=ordini_confermati" voci={ordini.map(p => ({ id: p.id, codice: p.codice_pratica || p.id }))}>
  <section role="alert" className="mb-6 rounded-2xl border-2 border-red-700 bg-red-50 p-5 text-red-950 shadow-sm">
    <p className="text-xl font-black">⚠ {ordini.length} ORDINI DA FATTURARE</p>
    <p className="mt-2 font-semibold">{pronti} pronti da fatturare · {ordini.length - pronti} con controllo anagrafica o dati da completare</p>
    <p className="mt-1 text-sm">Solo fatturazione: questo avviso non rappresenta gli ordini da evadere. L’evasione ha una coda separata e non si chiude con la fattura.</p>
    <div className="mt-3 flex flex-wrap gap-2">{ordini.slice(0,5).map(p => <ApriPraticaConContesto key={p.id} praticaId={p.id} sezione="amministrazione" className="rounded-lg border border-red-300 bg-white px-3 py-2 text-sm font-bold">{p.targa || p.codice_pratica} · {p.nome_cliente || 'Cliente da identificare'} →</ApriPraticaConContesto>)}</div>
    <Link href="/?filtro=ordini_confermati" prefetch={false} className="mt-4 inline-flex rounded-lg bg-red-800 px-4 py-3 font-bold text-white">Vedi gli ordini da fatturare →</Link>
  </section></ContestoNavigazioneElenco>;
}
