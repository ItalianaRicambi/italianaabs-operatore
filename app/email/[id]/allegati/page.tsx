import Link from 'next/link';
import {notFound,redirect} from 'next/navigation';
import {getOperatoreAttivo} from '../../../operatore';
import {BarraOperatore} from '../../../components/IdentitaOperatore';
import {leggiRichiestaEmail} from '../../../lib/richiesteEmailServer';
import {leggiMessaggiConversazioneKeplero} from '../../../lib/kepleroMessagesServer';
import {ErroreMessaggiKeplero} from '../../../lib/kepleroMessages';
import {riepilogoAllegatiConversazione} from '../../../lib/allegatiConversazioneKeplero';
import {linkConversazioneEmail} from '../../../lib/richiesteEmail';
export const runtime='nodejs';
export const maxDuration=60;
const ERRORI:Record<string,string>={non_configurato:'Il collegamento ai file Keplero non è configurato sul server.',non_autorizzato:'Keplero non autorizza il recupero: verificare la chiave API e i suoi permessi.',non_disponibile:'Recupero temporaneamente non disponibile. Riprovare più tardi.',risposta_non_valida:'La risposta di Keplero non coincide con il formato previsto. Gli allegati restano da verificare nell’originale.',limite_superato:'La conversazione supera i limiti di recupero. Verificare i file nell’originale.'};
export default async function AllegatiEmail({params}:{params:Promise<{id:string}>}){
 const operatore=await getOperatoreAttivo();if(!operatore)redirect('/');
 const {id}=await params;
 if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id))notFound();
 const e=await leggiRichiestaEmail(id);if(!e)notFound();
 let riepilogo:ReturnType<typeof riepilogoAllegatiConversazione>|null=null,errore:string|null=null;
 try{riepilogo=riepilogoAllegatiConversazione(await leggiMessaggiConversazioneKeplero(e.conversation_id));}
 catch(error){
  errore=ERRORI[error instanceof ErroreMessaggiKeplero?error.codice:'non_disponibile']||ERRORI.non_disponibile;
  if(error instanceof ErroreMessaggiKeplero && error.statoHttp===401) errore='La credenziale API viene rifiutata da Keplero (401). Verificare la chiave salvata sul server.';
  if(error instanceof ErroreMessaggiKeplero && error.statoHttp===403) errore='Keplero nega il permesso di leggere questa conversazione (403). Verificare con l’assistenza l’accesso della chiave all’assistente collegato alla casella email.';
 }
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={operatore}/><div className="mx-auto max-w-4xl px-6 py-8">
 <Link href="/email" className="font-bold text-blue-800 underline">Torna alle richieste email</Link><h1 className="mt-4 text-3xl font-bold">Allegati originali in Keplero</h1><p className="mt-3 font-semibold">{e.subject||'(senza oggetto)'}</p>
 <p className="mt-3 text-slate-700">I file elencati appartengono alla conversazione. Prima di usarli, verificare il messaggio e il veicolo a cui si riferiscono. Il recupero non modifica la pratica e non conferma la lettura delle immagini.</p>
 <div className="mt-4 flex flex-wrap gap-5">{e.pratica_id&&<Link href={`/pratica/${e.pratica_id}`} className="font-bold text-blue-800 underline">Apri pratica</Link>}<a href={linkConversazioneEmail(e.conversation_id)} target="_blank" rel="noopener noreferrer" className="font-bold text-blue-800 underline">Apri conversazione originale in K</a></div>
 {errore&&<p role="alert" className="mt-6 rounded-xl border border-amber-300 bg-amber-50 p-5">{errore}</p>}
 {riepilogo&&<section className="mt-6 rounded-xl border bg-white p-5"><h2 className="text-xl font-bold">Recupero completato</h2><p className="mt-2">Messaggi recuperati: {riepilogo.totale} · Email: {riepilogo.email} · File esposti dall’API: {riepilogo.files.length}</p>
 {!riepilogo.files.length&&<p className="mt-3 text-amber-900">L’API non espone allegati nel formato documentato. Questo non significa che l’email non contenga file: verificare la conversazione originale.</p>}
 <ul className="mt-4 space-y-3">{riepilogo.files.map((f,i)=><li key={`${f.messaggioId}-${i}`} className="rounded-lg border p-3"><a href={f.url} target="_blank" rel="noopener noreferrer" className="break-all font-semibold text-blue-800 underline">{f.nome}</a><p className="mt-1 text-sm text-slate-600">{f.tipo==='image'?'Immagine':'Documento'}{f.messaggioId?` · Messaggio ${f.messaggioId}`:''}</p></li>)}</ul></section>}
 </div></main>;
}
