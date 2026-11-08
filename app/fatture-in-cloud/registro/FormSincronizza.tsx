'use client';
import { useActionState } from 'react';
import { sincronizzaRegistroFic } from './actions';
import { TIPI_FIC } from '../../lib/fattureInCloud';
export default function FormSincronizza({oggi}:{oggi:string}) {
  const [stato, action, pending] = useActionState(sincronizzaRegistroFic, {messaggio:'',ok:false});
  return <form action={action} className="my-5 rounded-xl border bg-white p-5">
    <h2 className="mb-3 text-lg font-bold">Aggiorna il registro</h2>
    <div className="flex flex-wrap items-end gap-4">
      <label>Documento<select name="tipo" className="block rounded border p-2">{Object.entries(TIPI_FIC).map(([k,v])=><option key={k} value={k}>{v}</option>)}</select></label>
      <label>Dal<input required name="dal" type="date" defaultValue={oggi.slice(0,8)+'01'} className="block rounded border p-2" /></label>
      <label>Al<input required name="al" type="date" defaultValue={oggi} className="block rounded border p-2" /></label>
      <button disabled={pending} className="rounded bg-blue-800 px-4 py-2 font-bold text-white disabled:opacity-50">{pending?'Sincronizzazione…':'Sincronizza documenti'}</button>
    </div>
    <p className="mt-3 text-sm text-slate-600">Massimo 31 giorni. Gli stessi documenti vengono aggiornati senza duplicarli. L’abbinamento suggerito richiede verifica.</p>
    {stato.messaggio&&<p role={stato.ok?'status':'alert'} className={`mt-3 ${stato.ok?'text-green-800':'text-red-800'}`}>{stato.messaggio}</p>}
  </form>;
}
