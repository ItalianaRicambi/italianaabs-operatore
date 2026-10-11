'use client';
import { useActionState } from 'react';
import { configuraSmtpLogistica, cambiaInvioLogistica } from '../logistica/email/actions';

const iniziale = { errore: null, successo: null };
export function ConfigurazioneEmailLogistica({ configurata, abilitata }: { configurata: boolean; abilitata: boolean }) {
  const [smtp, salva, salvando] = useActionState(configuraSmtpLogistica, iniziale);
  const [invio, cambia, cambiando] = useActionState(cambiaInvioLogistica, iniziale);
  return <section className="my-5 rounded-xl border border-slate-200 bg-white p-5">
    <h2 className="text-xl font-bold">Collegamento casella spedizioni</h2>
    <p className="mt-2 text-sm">Mittente: <strong>spedizioni@italianaabs.com</strong> · Firma: Ufficio logistico.</p>
    <p className="mt-2 text-sm">{configurata ? 'Collegamento salvato.' : 'Inserisci qui la password della casella spedizioni per collegarla e inviare una prova interna.'} La password non viene mostrata dopo il salvataggio.</p>
    <form action={salva} className="mt-4 flex flex-wrap items-end gap-3">
      <label className="text-sm font-semibold">Password casella spedizioni<input type="password" name="password" required maxLength={1000} autoComplete="new-password" className="mt-1 block rounded-lg border border-slate-300 px-3 py-2" /></label>
      <button disabled={salvando} className="rounded-lg bg-blue-700 px-4 py-2 font-semibold text-white disabled:opacity-50">{salvando ? 'Collaudo in corso…' : 'Collega e invia prova'}</button>
    </form>
    <p className="mt-2 text-xs text-slate-600">La prova viene inviata a paolo.ardizzoia78@gmail.com. Non avvia pratiche o ritiri.</p>
    {smtp.errore && <p role="alert" className="mt-3 text-red-800">{smtp.errore}</p>}
    {smtp.successo && <p role="status" className="mt-3 text-green-800">{smtp.successo}</p>}
    <form action={cambia} className="mt-5 border-t border-slate-200 pt-4">
      <input type="hidden" name="abilita" value={abilitata ? 'false' : 'true'} />
      {!abilitata && <label className="block text-sm"><input type="checkbox" name="ricezione_confermata" required className="mr-2" />Ho ricevuto la mail di collaudo dalla casella spedizioni.</label>}
      <button disabled={cambiando || (!configurata && !smtp.successo)} className="mt-3 rounded-lg border border-blue-700 px-4 py-2 font-semibold text-blue-800 disabled:opacity-40">{cambiando ? 'Salvataggio…' : abilitata ? 'Sospendi avvisi automatici' : 'Attiva avvisi automatici'}</button>
    </form>
    {invio.errore && <p role="alert" className="mt-3 text-red-800">{invio.errore}</p>}
    {invio.successo && <p role="status" className="mt-3 text-green-800">{invio.successo}</p>}
  </section>;
}
