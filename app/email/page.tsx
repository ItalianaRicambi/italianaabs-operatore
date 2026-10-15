import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getOperatoreAttivo } from '../operatore';
import { BarraOperatore } from '../components/IdentitaOperatore';
import { leggiRichiesteEmail } from '../lib/richiesteEmailServer';
import { linkConversazioneEmail } from '../lib/richiesteEmail';
import { gestitaEmail,riprovaEmail } from './actions';
const NOMI:Record<string,string>={registrata:'Collegata alla pratica',da_classificare:'Da classificare',in_elaborazione:'Elaborazione in corso',errore:'Elaborazione da riprovare',esclusa:'Collaudo / notifica tecnica',gestita:'Gestita dall’operatore'};
export default async function EmailRicevute(){
 const operatore=await getOperatoreAttivo();if(!operatore) redirect('/');
 let righe;try{righe=await leggiRichiesteEmail();}catch{righe=null;}
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={operatore}/><div className="mx-auto max-w-5xl px-6 py-8">
 <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link><h1 className="mt-4 text-3xl font-bold">Richieste email</h1>
 <p className="mt-2 text-slate-600">info@italianaabs.com · messaggi ricevuti tramite Keplero</p>
 <p className="mt-3 text-sm text-slate-600">Ogni richiesta conserva mittente, oggetto e testo originale. Le email con allegati non trasmessi richiedono la verifica dell’originale in Keplero. Questa sezione non invia risposte al cliente.</p>
 {!righe?<p role="alert" className="mt-5 text-red-800">Registro email non disponibile. Verificare il collegamento prima di considerare tutte le richieste acquisite.</p>:<>
 <p className="my-5 font-semibold">Da classificare / errori: {righe.filter(e=>['da_classificare','errore','in_elaborazione'].includes(e.stato)).length} · Messaggi mostrati: {righe.length} (massimo 200)</p>
 {!righe.length && <p className="rounded-xl border bg-white p-5">Nessuna email ancora registrata.</p>}
 <div className="space-y-4">{righe.map(e=><section key={e.id} className={`rounded-xl border bg-white p-5 ${['errore','da_classificare'].includes(e.stato)?'border-amber-400':'border-slate-200'}`}>
 <div className="flex flex-wrap justify-between gap-2"><h2 className="font-bold">{e.subject||'(senza oggetto)'}</h2><strong className="text-sm">{NOMI[e.stato]||e.stato}</strong></div>
 <p className="mt-2 break-all text-sm">{e.sender} · Acquisita {new Date(e.created_at).toLocaleString('it-IT',{timeZone:'Europe/Rome'})}</p>
 {e.motivo&&<p className="mt-2 text-sm text-amber-950">{e.motivo}</p>}
 <div className="mt-3 flex flex-wrap gap-4"><Link href={`/email/${e.id}/allegati`} className="font-bold text-blue-800 underline">Verifica allegati in K</Link>{e.pratica_id&&<Link href={`/pratica/${e.pratica_id}`} className="font-bold text-blue-800 underline">Apri pratica</Link>}<a href={linkConversazioneEmail(e.conversation_id)} target="_blank" rel="noopener noreferrer" className="font-bold text-blue-800 underline">Apri email originale in K</a></div>
 <details className="mt-3 text-sm"><summary className="cursor-pointer font-semibold">Testo originale</summary><pre className="mt-3 whitespace-pre-wrap break-words rounded-lg bg-slate-50 p-3 font-sans">{e.content}</pre></details>
 {['errore','in_elaborazione'].includes(e.stato)&&<form action={riprovaEmail} className="mt-3"><input type="hidden" name="id" value={e.id}/><button className="rounded-lg bg-blue-700 px-4 py-2 font-semibold text-white">Riprova elaborazione</button></form>}
 {['registrata','da_classificare'].includes(e.stato)&&<form action={gestitaEmail} className="mt-3"><input type="hidden" name="id" value={e.id}/><button className="rounded-lg border border-blue-300 px-4 py-2 font-semibold text-blue-900">Segna email gestita</button></form>}
 </section>)}</div></>}
 </div></main>;
}
