import Link from 'next/link';
import type { DocumentoPreventivoAuto } from '../lib/documentiPreventivoServer';
const euro=(n:number)=>new Intl.NumberFormat('it-IT',{style:'currency',currency:'EUR'}).format(n);
export function DocumentiPreventivoAutomatici({documenti}:{documenti:DocumentoPreventivoAuto[]}) {
 if(!documenti.length)return null;
 return <section className="mt-4 rounded-xl border border-blue-300 bg-blue-50 p-4">
 <h3 className="font-bold text-blue-950">Preventivi acquisiti automaticamente</h3>
 <p className="mt-2 text-sm">Le proposte sono già disponibili. Il documento archiviato non conferma l’invio al cliente.</p>
 {documenti.map(d=><div key={d.id} className="mt-3 rounded-lg border bg-white p-3">
 <p className="font-bold">{d.nome_file} · {d.stato==='pronto'?'Pronto · invio da verificare':d.stato==='da_abbinare'?'Abbinamento da verificare':'Lettura da verificare'}</p>
 <p className="mt-1 text-xs">Acquisito {new Date(d.ricevuto_at).toLocaleString('it-IT',{timeZone:'Europe/Rome'})}</p>
 {d.motivo&&<p className="mt-2 text-sm">{d.motivo}</p>}
 {d.file_url&&/^https:\/\//.test(d.file_url)&&<a className="mt-2 inline-block font-semibold text-blue-800 underline" href={d.file_url} target="_blank" rel="noreferrer">Apri PDF</a>}
 <ul className="mt-2 space-y-1 text-sm">{d.opzioni.map(o=><li key={o.numero}>{o.numero_esplicito?`Opzione ${o.numero} · `:''}{o.descrizione||o.servizio} · {euro(o.importo)}{o.iva_inclusa===true?' IVA inclusa':o.iva_inclusa===false?' + IVA':' · IVA da verificare'}</li>)}</ul>
 </div>)}
 <Link href="/preventivi" className="mt-3 inline-block text-sm font-bold text-blue-800 underline">Apri registro dei preventivi da verificare</Link>
 </section>;
}
