'use client';
import { useActionState } from 'react';
import { aggiornaEvasione } from './actions';
export function FormEvasione({id,revisione,stato,tipo}:{id:string;revisione?:number;stato?:string;tipo:'evasione'|'verifica'}) {
 const [esito,action,pending] = useActionState(aggiornaEvasione,{errore:'',ok:false});
 return <details className="mt-3 border-t pt-3"><summary className="cursor-pointer font-bold">{tipo==='verifica'?'Chiudi verifica con motivazione':'Aggiorna evasione con prova'}</summary>
 <form action={action} className="mt-3 space-y-3">
  <input type="hidden" name="id" value={id}/><input type="hidden" name="tipo" value={tipo}/>
  <input type="hidden" name="revisione" value={revisione || ''}/>
  {tipo==='evasione' && <label className="block">Stato di evasione <select name="stato" defaultValue={stato} className="ml-3 rounded border p-2"><option value="da_evadere">Da evadere</option><option value="evaso">Evaso</option><option value="da_verificare">Da verificare</option></select></label>}
  <label className="block">Prova / motivazione (per evasione: spedizione effettiva, ritiro in sede o intervento concluso)<textarea required minLength={12} maxLength={2000} name="nota" className="mt-1 block w-full rounded border p-2"/></label>
  <p className="text-xs">Non modifica fatture, importi, pagamenti, classificazione o blocchi della pratica. Non invia messaggi.</p>
  <button disabled={pending} className="rounded bg-blue-900 px-4 py-2 font-bold text-white disabled:opacity-50">{pending?'Registrazione…':'Conferma manualmente'}</button>
  {esito.errore && <p role="alert" className="text-red-800">{esito.errore}</p>}{esito.ok && <p role="status">Registrato nello storico operatore.</p>}
 </form></details>;
}
