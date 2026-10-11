import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getOperatoreAttivo } from '../../operatore';
import { BarraOperatore } from '../../components/IdentitaOperatore';
import { ConfigurazioneEmailLogistica } from '../../components/ConfigurazioneEmailLogistica';
import { VerificaEmailLogistica } from '../../components/VerificaEmailLogistica';
import { leggiConfigEmail, leggiNotificheEmail } from '../../lib/emailLogisticaServer';
import { messaggioPresa } from '../../lib/emailLogistica';
import { rivalutaAvvisoLogistica } from './actions';

const NOMI: Record<string, string> = { in_attesa: 'In attesa di invio', da_verificare: 'Da verificare', in_invio: 'Invio in corso', inviata: 'Accettata dal server di posta', errore: 'Invio non riuscito', esito_incerto: 'Esito incerto: verifica richiesta', annullata: 'Avviso annullato' };
export default async function EmailLogistica() {
  const operatore = await getOperatoreAttivo(); if (!operatore) redirect('/');
  const [config, coda] = await Promise.allSettled([leggiConfigEmail(), leggiNotificheEmail()]);
  return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={operatore} /><div className="mx-auto max-w-5xl px-6 py-8">
    <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link>
    <h1 className="mt-4 text-3xl font-bold">Email ritiri e spedizioni</h1>
    <p className="mt-2 text-sm text-slate-600">Avvisi GLS per lavorazioni, verifiche in garanzia e rientri Programma Scambio.</p>
    {config.status === 'fulfilled' ? <><p className={`mt-4 rounded-lg p-4 font-semibold ${config.value.abilitata ? 'bg-green-100 text-green-950' : 'bg-amber-100 text-amber-950'}`}>{config.value.abilitata ? 'Avvisi automatici attivi · controllo ogni 5 minuti' : 'Avvisi automatici sospesi'}</p><ConfigurazioneEmailLogistica configurata={config.value.configurata} abilitata={config.value.abilitata} /></> : <p role="alert" className="my-5 text-red-800">Configurazione non disponibile. Riprova prima di inviare.</p>}
    <p className="mb-4 text-sm text-slate-600">Le prese precedenti all’attivazione del registro non vengono recuperate. Un avviso con esito incerto richiede la verifica del Message-ID presso il servizio di posta. L’accettazione SMTP non conferma la consegna nella casella del cliente.</p>
    <p className="mb-5 text-sm text-slate-600">Tracking MBE: collegamento dei dati ancora da completare.</p>
    {coda.status === 'rejected' ? <p role="alert" className="text-red-800">Registro invii non disponibile.</p> : <>
      <h2 className="mb-4 text-xl font-bold">Ultimi avvisi ({coda.value.length}, massimo 200)</h2>
      {!coda.value.length && <p className="rounded-xl border border-slate-200 bg-white p-5">Nessun avviso registrato. Le nuove prenotazioni confermate appariranno qui.</p>}
      <div className="space-y-4">{coda.value.map(n => {
        let anteprima = ''; try { anteprima = messaggioPresa(n).text; } catch { /* data trascorsa o codice da verificare */ }
        return <section key={n.id} className="rounded-xl border border-slate-200 bg-white p-5">
          <div className="flex flex-wrap justify-between gap-2"><h3 className="font-bold">GLS {n.riferimento} · {n.data_ritiro.split('-').reverse().join('/')}</h3><strong className="text-sm">{NOMI[n.stato] || n.stato}</strong></div>
          <p className="mt-2 text-sm">Destinatario: {n.destinatario || 'da verificare prima dell’invio'} · Revisione {n.revisione} · Tentativi {n.tentativi}</p>
          {n.motivo && <p className="mt-2 text-sm text-amber-950">{n.motivo}</p>}
          {n.inviata_at && <p className="mt-2 text-sm">Accettata il {new Date(n.inviata_at).toLocaleString('it-IT', { timeZone: 'Europe/Rome' })}</p>}
          {n.message_id && <p className="mt-2 break-all text-xs text-slate-600">Message-ID: {n.message_id}</p>}
          <Link href={`/pratica/${n.pratica_id}`} className="mt-3 inline-block font-semibold text-blue-800 underline">Apri pratica</Link>
          {anteprima && <details className="mt-3 text-sm"><summary className="cursor-pointer font-semibold">Testo avviso (oggi/domani calcolati al momento dell’invio)</summary><p className="mt-3 whitespace-pre-line">{anteprima}</p></details>}
          {['errore', 'da_verificare'].includes(n.stato) && <form action={rivalutaAvvisoLogistica} className="mt-3"><input type="hidden" name="id" value={n.id} /><button className="rounded-lg border border-blue-700 px-3 py-2 text-sm font-semibold text-blue-800">Verifica nuovamente i dati e rimetti in coda</button></form>}
          {n.stato === 'esito_incerto' && <VerificaEmailLogistica id={n.id} />}
        </section>;
      })}</div>
    </>}
  </div></main>;
}
