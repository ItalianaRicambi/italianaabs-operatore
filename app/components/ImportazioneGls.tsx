'use client';
import { useActionState } from 'react';
import { importaDettaglioGls, abbinaEsitoGls } from '../gls/actions';
const input = 'mt-1 w-full rounded-lg border border-slate-300 bg-white p-2 text-sm';
const button = 'rounded-lg bg-blue-700 px-3 py-2 text-sm font-bold text-white disabled:opacity-50';
export function ImportazioneGls() {
 const [state, action, pending] = useActionState(importaDettaglioGls, { ok: false, messaggio: '' });
 return <details className="mb-6 rounded-xl border border-blue-200 bg-white p-4">
  <summary className="cursor-pointer font-bold text-blue-900">Registra un controllo dal portale GLS</summary>
  <form action={action} className="mt-3 space-y-3">
   <p className="text-sm text-slate-600">Cerca la presa nel portale e copia il dettaglio completo, inclusa la tabella degli esiti. Se GLS apre il tracking della spedizione, conserva il codice e la data della presa originaria.</p>
   <div className="grid gap-3 sm:grid-cols-2">
    <label className="text-sm font-semibold">Codice della presa<input name="riferimento" className={input} placeholder="P3 9260993058" maxLength={50} required /></label>
    <label className="text-sm font-semibold">Data prevista della presa<input name="data_ritiro" className={input} type="date" required /></label>
   </div>
   <label className="block text-sm font-semibold">Dettaglio e storico GLS<textarea name="testo" className={input} rows={7} maxLength={100000} required /></label>
   <label className="flex items-start gap-2 text-sm"><input type="checkbox" name="verificata" required />Ho verificato nel portale GLS codice, mittente, destinatario e storico di questa presa.</label>
   <button className={button} disabled={pending}>{pending ? 'Registrazione…' : 'Registra esito GLS'}</button>
   {state.messaggio && <p role="status" className={state.ok ? 'text-sm text-green-800' : 'text-sm text-red-800'}>{state.messaggio}</p>}
  </form>
 </details>;
}
export function AbbinamentoEsitoGls({ esitoId, ritiri }: { esitoId: string; ritiri: { id: string; label: string }[] }) {
 const [state, action, pending] = useActionState(abbinaEsitoGls, { ok: false, messaggio: '' });
 return <form action={action} className="mt-3 space-y-2">
  <input type="hidden" name="esito_id" value={esitoId} />
  <label className="block text-sm font-semibold">Ritiro della pratica<select name="attivita_id" className={input} defaultValue="" required>
   <option value="" disabled>Seleziona dopo aver verificato i dati</option>{ritiri.map(a => <option key={a.id} value={a.id}>{a.label}</option>)}
  </select></label>
  <label className="flex items-start gap-2 text-sm"><input type="checkbox" name="verificata" required />Ho verificato che cliente, codice, data e destinazione riguardino questo ritiro. Confermo anche la prenotazione indicata.</label>
  <button className={button} disabled={pending}>{pending ? 'Registrazione…' : 'Conferma abbinamento GLS'}</button>
  {state.messaggio && <p role="status" className={state.ok ? 'text-sm text-green-800' : 'text-sm text-red-800'}>{state.messaggio}</p>}
 </form>;
}
