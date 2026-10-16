import Link from 'next/link';
import {redirect} from 'next/navigation';
import {getOperatoreAttivo} from '../operatore';
import {BarraOperatore} from '../components/IdentitaOperatore';
import {leggiDocumentiPreventivo} from '../lib/documentiPreventivoServer';
import {DocumentiPreventivoAutomatici} from '../components/DocumentiPreventivoAutomatici';
export const dynamic='force-dynamic';
export default async function RegistroPreventivi(){
 const operatore=await getOperatoreAttivo();if(!operatore)redirect('/');
 let documenti;try{documenti=await leggiDocumentiPreventivo();}catch{documenti=null;}
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={operatore}/><div className="mx-auto max-w-5xl px-6 py-8">
 <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link>
 <h1 className="mt-4 text-3xl font-bold">Preventivi acquisiti · verifiche</h1>
 <p className="mt-3">I PDF vengono acquisiti senza premere «Preventivo inviato». Per segnare l’invio serve il messaggio originale in uscita oppure la conferma dell’operatore. Pratiche ambigue e correzioni manuali restano da verificare.</p>
 <p className="mt-3 rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm">Riconoscimento automatico degli invii in chat: da collaudare con il collegamento Keplero autorizzato. La presenza del PDF in Drive non viene usata come prova d’invio.</p>
 {documenti===null?<p role="alert" className="mt-5 text-red-800">Registro non disponibile: verificare l’acquisizione dei PDF.</p>:<>
 <p className="mt-5 font-semibold">Documenti mostrati: {documenti.length} (massimo 200) · Da abbinare: {documenti.filter(d=>d.stato==='da_abbinare').length}</p>
 {!documenti.length&&<p className="mt-4 rounded-xl border bg-white p-5">Nessun documento in attesa di verifica.</p>}
 {documenti.map(d=><div key={d.id} className="mt-5">
 <p className="font-semibold">Targa {d.targa}{d.pratica_id&&<> · <Link href={`/pratica/${d.pratica_id}`} className="text-blue-800 underline">Apri pratica</Link></>}</p>
 <DocumentiPreventivoAutomatici documenti={[d]}/></div>)}
 </>}
 </div></main>;
}
