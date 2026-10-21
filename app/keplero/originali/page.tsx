import Link from 'next/link';
import {redirect} from 'next/navigation';
import {getOperatoreAttivo} from '../../operatore';
import {BarraOperatore} from '../../components/IdentitaOperatore';
import {StatoOriginaliK} from '../../components/StatoOriginaliK';
import {connessioneGlsDb} from '../../lib/glsServer';
import {archiviaOriginaleK} from './actions';
export const dynamic='force-dynamic';
type Riga={sessione:string;messaggio_id:string;pratica_id:string|null;esito:string;motivo:string;keplero_originali:{testo:string;data_messaggio:string;direzione:string;modificato:boolean;revisione:{testo?:string}|null};pratiche:{numero_pratica:number;targa:string|null;nome_cliente:string|null}|null};
export default async function OriginaliK(){
 const op=await getOperatoreAttivo();if(!op)redirect('/');
 const {url,headers}=connessioneGlsDb();
 let righe:Riga[]|null=null;
 try{const r=await fetch(`${url}/rest/v1/keplero_verifiche_originali?select=*,keplero_originali(testo,data_messaggio,direzione,modificato,revisione),pratiche(numero_pratica,targa,nome_cliente)&esito=eq.da_verificare&order=created_at.desc&limit=200`,{headers,cache:'no-store',signal:AbortSignal.timeout(10000)});if(r.ok)righe=await r.json();}catch{}
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={op}/><div className="mx-auto max-w-5xl px-6 py-8">
 <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link><h1 className="my-5 text-3xl font-bold">Conferme e documenti dalle chat originali</h1><StatoOriginaliK/>
 <p className="mb-5 rounded-lg border bg-blue-50 p-4">Il controllo scopre le conversazioni aggiornate e conserva i messaggi originali, anche mentre risponde un operatore. Solo un consenso letterale con offerta e alternativa uniche può recuperare l’ordine. Scelte ambigue, revoche, fatture e pagamenti richiedono verifica. Le chat senza pratica compatibile restano visibili come verifiche da abbinare.</p>
 {righe===null?<p role="alert">Registro non disponibile. Riprovare.</p>:!righe.length?<p>Nessuna verifica in attesa.</p>:<><p className="mb-4">Mostrate le ultime {righe.length} verifiche (massimo 200).</p>{righe.map(r=><article key={`${r.sessione}:${r.messaggio_id}`} className="mb-4 rounded-xl border bg-white p-5">
 <h2 className="font-bold">{r.pratiche?`ABS-${String(r.pratiche.numero_pratica).padStart(6,'0')} · ${r.pratiche.targa||'Targa da verificare'} · ${r.pratiche.nome_cliente||''}`:'Pratica da abbinare'}</h2>
 <p className="mt-2 text-sm">{new Date(r.keplero_originali.data_messaggio).toLocaleString('it-IT',{timeZone:'Europe/Rome'})} · {r.keplero_originali.direzione==='entrata'?'Cliente':'Messaggio inviato'} · ID {r.messaggio_id}</p>
 <p className="mt-3 font-semibold text-amber-900">{r.motivo}</p><p className="mt-3 whitespace-pre-wrap break-all text-sm">{r.keplero_originali.testo.slice(0,3000)}</p>
 {r.keplero_originali.modificato&&<p className="mt-3 whitespace-pre-wrap text-sm">Revisione successiva: {r.keplero_originali.revisione?.testo?.slice(0,3000)}</p>}
 <div className="mt-4 flex flex-wrap gap-5">{r.pratica_id&&<Link href={`/pratica/${r.pratica_id}`} className="font-bold text-blue-800 underline">Apri pratica</Link>}<a href={`https://console.keplero.ai/dashboard/2aef20d3-5ef8-4c81-8f21-bd450f22960c/conversations?sessionId=${r.sessione}`} target="_blank" rel="noreferrer" className="font-bold text-blue-800 underline">Leggi chat originale</a></div>
 <form action={archiviaOriginaleK} className="mt-4"><input type="hidden" name="sessione" value={r.sessione}/><input type="hidden" name="messaggio" value={r.messaggio_id}/><button className="rounded-lg border px-3 py-2 text-sm font-bold">Verifica eseguita · archivia avviso</button><p className="mt-2 text-xs text-slate-500">Archivia soltanto l’avviso. Le correzioni di scelta, ordine o fattura si salvano nella pratica.</p></form>
 </article>)}</>}
 </div></main>;
}
