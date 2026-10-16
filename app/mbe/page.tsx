import Link from 'next/link';
import {redirect} from 'next/navigation';
import {getOperatoreAttivo} from '../operatore';
import {BarraOperatore} from '../components/IdentitaOperatore';
import {SpedizioniMbe} from '../components/SpedizioniMbe';
import {credenzialiMbePresenti,collaudoMbeRecente,leggiMbe,leggiCollegamentoMbe} from '../lib/mbeServer';
import {ComandiMbe} from './ComandiMbe';
export const dynamic='force-dynamic';
export const maxDuration=60;
export default async function RegistroMbe() {
 const operatore=await getOperatoreAttivo();if(!operatore)redirect('/');
 const [righe,stato]=await Promise.all([leggiMbe().catch(()=>null),leggiCollegamentoMbe().catch(()=>null)]);
 const configurato=credenzialiMbePresenti();
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={operatore}/><div className="mx-auto max-w-5xl px-6 py-8">
 <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link><h1 className="mt-4 text-3xl font-bold">Spedizioni MBE</h1>
 <p className="mt-3">Importazione e tracking delle spedizioni già presenti in MBE. Usa il riferimento «ABS-000123 — XX000XX» per collegarle alla pratica. I riferimenti mancanti o discordanti restano da verificare.</p>
 <p className="mt-3 rounded-lg border border-blue-200 bg-blue-50 p-4">L’email di tracking al destinatario è gestita da MBE quando inserisci la sua email nella spedizione. Questa integrazione non invia altri messaggi. La creazione della spedizione non prova il ritiro; lo stato del corriere non chiude la lavorazione o l’assistenza.</p>
 {!configurato&&<p className="mt-4 rounded-lg border border-amber-300 bg-amber-50 p-4"><strong>Da configurare.</strong> Nelle variabili server di Vercel imposta MBE_API_USERNAME e MBE_API_PASSWORD con le credenziali MBE Online e ridistribuisci l’applicazione. Non inserire le credenziali in chat. Poi premi «Verifica collegamento e sincronizza».</p>}
 {stato?<section className="mt-5 rounded-xl border bg-white p-5"><h2 className="text-xl font-bold">Collegamento: {stato.automatico?'aggiornamento ogni 15 minuti':stato.ultimo_successo_at?'collaudato · aggiornamento automatico sospeso':'da collaudare'}</h2>
 <p className="mt-2">Ultima lettura completa: {stato.ultimo_successo_at?new Date(stato.ultimo_successo_at).toLocaleString('it-IT',{timeZone:'Europe/Rome'}):'mai'} · Importate: {stato.importate} · Tracking controllati: {stato.controllate}</p>
 {stato.ultimo_errore&&<p role="alert" className="mt-3 text-red-800">{stato.ultimo_errore}</p>}
 <ComandiMbe automatico={stato.automatico} collaudato={collaudoMbeRecente(stato)}/></section>:<p role="alert" className="mt-4 text-red-800">Collegamento MBE non disponibile. Verificare il database.</p>}
 {righe===null?<p role="alert" className="mt-5 text-red-800">Registro MBE non disponibile.</p>:<><p className="mt-5 font-semibold">Spedizioni mostrate: {righe.length} (massimo 200, dalla più recente) · Da abbinare/verificare: {righe.filter(r=>r.abbinamento!=='abbinata').length} · Destinazione da classificare: {righe.filter(r=>r.tipo_destinazione==='da_classificare').length}</p><SpedizioniMbe righe={righe} classificabile/></>}
 </div></main>;
}
