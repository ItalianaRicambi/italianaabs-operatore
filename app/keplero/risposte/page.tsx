import Link from 'next/link';
import {redirect} from 'next/navigation';
import {getOperatoreAttivo} from '../../operatore';
import {BarraOperatore} from '../../components/IdentitaOperatore';
import {StatoRisposteK,type ControlloRisposteK} from '../../components/StatoRisposteK';
import {rpcOriginaliK} from '../../lib/originaliKepleroServer';
import {verificaRispostaK} from './actions';
export const dynamic='force-dynamic';
const data=(d:string)=>new Date(d).toLocaleString('it-IT',{timeZone:'Europe/Rome'});
export default async function RisposteK(){
 const op=await getOperatoreAttivo();if(!op)redirect('/');
 const s=await rpcOriginaliK<ControlloRisposteK>('controllo_risposte_k').catch(()=>null);
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={op}/><div className="mx-auto max-w-5xl px-6 py-8">
 <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link><h1 className="my-5 text-3xl font-bold">Clienti in attesa di risposta</h1><StatoRisposteK/>
 <p className="mb-5 rounded-lg border bg-blue-50 p-4">Controllare il messaggio originale prima di rispondere. Anche un ringraziamento può comparire qui: la verifica richiede un motivo. Un nuovo messaggio del cliente riapre il controllo. Un invio WhatsApp fallito o senza conferma di consegna non chiude l’attesa. Nessun messaggio viene inviato da questo pannello.</p>
 {!s?<p role="alert">Registro non disponibile.</p>:<>
 {s.esterne.length>0&&<><h2 className="mb-3 text-xl font-bold">Segnalazioni da WhatsApp assenti in K</h2>{s.esterne.map(r=><article key={r.id} className="mb-4 rounded-xl border border-red-300 bg-white p-5"><h3 className="font-bold">{r.nome} · {r.telefono}</h3><p className="mt-2 text-sm">{data(r.data_messaggio)} · Fonte: {r.fonte}</p><p className="mt-3 whitespace-pre-wrap">{r.testo}</p><p role="alert" className="mt-3 font-bold text-red-800">{r.nota}</p></article>)}</>}
 <h2 className="mb-3 text-xl font-bold">Messaggi acquisiti da verificare · {s.totale}</h2><p className="mb-4 text-sm">{s.chat.length} risultati mostrati, massimo 200. {s.recenti} conversazioni note attive nella finestra; {s.incomplete} letture incomplete.</p>
 {s.chat.map(r=><article key={`${r.sessione}:${r.messaggio_id}`} className="mb-4 rounded-xl border bg-white p-5"><h3 className="font-bold">{r.nome_cliente||'Cliente da identificare'}{r.telefono?` · ${r.telefono}`:''}{r.numero_pratica?` · ABS-${String(r.numero_pratica).padStart(6,'0')}`:''}</h3><p className="mt-2 text-sm">{data(r.data_messaggio)} · {r.assistente==='2aef20d3-5ef8-4c81-8f21-bd450f22960c'?'WhatsApp':'Altro canale K'} · ID {r.messaggio_id}</p><p className="mt-3 font-semibold text-amber-900">{r.motivo}</p><p className="mt-3 whitespace-pre-wrap break-all text-sm">{r.testo.slice(0,3000)}</p><div className="mt-4 flex gap-5"><a href={`https://console.keplero.ai/dashboard/${r.assistente||'2aef20d3-5ef8-4c81-8f21-bd450f22960c'}/conversations?sessionId=${r.sessione}`} target="_blank" rel="noreferrer" className="font-bold text-blue-800 underline">Apri chat originale</a>{r.pratica_id&&<Link href={`/pratica/${r.pratica_id}`} className="font-bold text-blue-800 underline">Apri pratica</Link>}</div><form action={verificaRispostaK} className="mt-4"><input type="hidden" name="sessione" value={r.sessione}/><input type="hidden" name="messaggio" value={r.messaggio_id}/><label className="block text-sm font-semibold">Motivo della verifica<input name="motivo" required minLength={5} maxLength={1000} placeholder="Es. solo ringraziamento; oppure risposta verificata in WhatsApp" className="mt-2 block w-full rounded-lg border p-2"/></label><button className="mt-3 rounded-lg border px-3 py-2 text-sm font-bold">Registra verifica operatore</button></form></article>)}
 {s.errori.length>0&&<details className="my-5 rounded-lg border bg-white p-4"><summary className="font-bold">Errori di acquisizione · {s.errori.length} mostrati</summary>{s.errori.map(e=><p key={e.sessione} className="mt-2 break-all text-sm">{e.sessione} · {e.errore}</p>)}</details>}
 </>}
 </div></main>;
}
