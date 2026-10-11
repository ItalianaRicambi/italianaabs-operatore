'use client';
import { useActionState } from 'react';
import { risolviAvvisoLogistica } from '../logistica/email/actions';
export function VerificaEmailLogistica({ id }: { id: string }) {
  const [stato, azione, caricamento] = useActionState(risolviAvvisoLogistica, { errore: null, successo: null });
  return <details className="mt-4 text-sm"><summary className="cursor-pointer font-bold">Registra il controllo dell’esito incerto</summary>
    <form action={azione} className="mt-3 space-y-3">
      <input type="hidden" name="id" value={id} />
      <label className="block">Esito verificato<select name="esito" required defaultValue="" className="ml-2 rounded border border-slate-300 p-2"><option value="" disabled>Seleziona esito</option><option value="inviata">Messaggio accettato dal server di posta</option><option value="errore">Messaggio non inviato / rifiutato</option></select></label>
      <label className="block">Prova del controllo (riscontro del servizio di posta)<textarea name="evidenza" required minLength={20} maxLength={2000} className="mt-1 block w-full rounded border border-slate-300 p-2" /></label>
      <label className="block"><input type="checkbox" name="verificato" required className="mr-2" />Ho verificato questo Message-ID con il servizio di posta.</label>
      <button disabled={caricamento} className="rounded-lg border border-blue-700 px-3 py-2 font-semibold text-blue-800">{caricamento ? 'Salvataggio…' : 'Registra verifica'}</button>
      {stato.errore && <p role="alert" className="text-red-800">{stato.errore}</p>}{stato.successo && <p role="status" className="text-green-800">{stato.successo}</p>}
    </form>
  </details>;
}
