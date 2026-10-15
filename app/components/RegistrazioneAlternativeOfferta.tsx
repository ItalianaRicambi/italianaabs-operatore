'use client';
import {useActionState} from 'react';
import {registraAlternativeOfferta} from '../pratica/[id]/actions';
const input='w-full rounded-lg border border-slate-300 bg-white p-2 text-sm';
export function RegistrazioneAlternativeOfferta({praticaId,preventivi,dataInvio}:{praticaId:string;preventivi:{id:string;inviato_at:string|null}[];dataInvio:string|null}){
 const [esito,azione,pending]=useActionState(registraAlternativeOfferta,{ok:false,messaggio:''});
 const abilitato=preventivi.length>0||!!dataInvio;
 return <div className="mt-4"><details open={preventivi.length===0||undefined}><summary className="cursor-pointer text-sm font-bold text-blue-800">Leggi un PDF o registra le alternative</summary>
 {!preventivi.length&&<p className="mt-3 rounded-lg bg-amber-50 p-3 text-sm text-amber-950">{dataInvio?`Invio dichiarato il ${new Date(dataInvio).toLocaleString('it-IT',{timeZone:'Europe/Rome'})}. Il documento e le alternative non sono ancora collegati. Inserisci soltanto le soluzioni e i prezzi del preventivo effettivo.`:'Nessun preventivo collegato. Per registrare le alternative di un preventivo già inviato, registra prima l’invio nella sezione commerciale.'}</p>}
 <form action={azione} className="mt-3 space-y-3"><input type="hidden" name="pratica_id" value={praticaId}/>
 {preventivi.length>0&&<label className="block text-sm">Preventivo<select className={input} name="preventivo_id" required disabled={pending}>{preventivi.map(p=><option key={p.id} value={p.id}>{p.inviato_at?new Date(p.inviato_at).toLocaleString('it-IT',{timeZone:'Europe/Rome'}):'Preventivo'} · {p.id.slice(0,8)}</option>)}</select></label>}
 <fieldset disabled={pending||!abilitato} className="space-y-3 disabled:opacity-60">
 <label className="block text-sm">PDF originale, massimo 3 MB<input className={input} type="file" name="pdf" accept="application/pdf"/></label>
 <p className="text-xs text-slate-500">In alternativa al PDF, trascrivi servizio, prezzo e IVA delle soluzioni realmente offerte.</p>
 {Array.from({length:4},(_,i)=><div key={i} className="grid grid-cols-3 gap-2"><select className={input} name={`servizio_${i+1}`} aria-label={`Servizio opzione ${i+1}`}><option value="">Opzione {i+1}</option>{['RI','RE','PS','PSMI'].map(s=><option key={s}>{s}</option>)}</select><input className={input} name={`importo_${i+1}`} placeholder="Importo €" inputMode="decimal" aria-label={`Prezzo opzione ${i+1}`}/><select className={input} name={`iva_${i+1}`} aria-label={`IVA opzione ${i+1}`}><option value="">IVA da verificare</option><option value="inclusa">IVA inclusa</option><option value="esclusa">IVA esclusa</option></select></div>)}
 <textarea className={input} name="nota" placeholder="Condizioni o annotazioni del preventivo"/>
 <button className="rounded-lg bg-slate-900 px-3 py-2 text-sm font-bold text-white disabled:opacity-50">{pending?'Salvataggio…':'Registra alternative'}</button></fieldset></form></details>
 {esito.messaggio&&<p role="status" aria-live="polite" className={`mt-3 rounded-lg p-3 text-sm font-semibold ${esito.ok?'bg-green-50 text-green-800':'bg-amber-50 text-amber-950'}`}>{esito.messaggio}</p>}
 </div>;
}
