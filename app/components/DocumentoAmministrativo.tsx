'use client';
import { useActionState } from 'react';
import { importaDocumentoAmministrativo } from '../pratica/[id]/actions';

export function ImportazioneDocumentoAmministrativo({ praticaId }: { praticaId: string }) {
  const [esito, azione, pending] = useActionState(importaDocumentoAmministrativo, { ok: false, messaggio: '' });
  return <details className="mb-4 rounded-xl border border-blue-200 bg-blue-50 p-4">
    <summary className="cursor-pointer text-sm font-bold text-blue-900">Registra fattura o pro-forma già emessa</summary>
    <p className="mt-3 text-sm text-slate-700">Carica il documento originale: vengono verificati targa, destinatario, numero e data. La fattura aggiorna la pratica a Fatturata; la pro-forma completa i dati amministrativi e lascia l’ordine da fatturare.</p>
    <form action={azione} className="mt-3 space-y-3">
      <input type="hidden" name="pratica_id" value={praticaId} />
      <label className="block text-sm">PDF originale, massimo 3 MB
        <input type="file" name="pdf" accept="application/pdf" required disabled={pending} className="mt-1 block w-full text-sm" />
      </label>
      <label className="flex items-start gap-2 text-sm"><input type="checkbox" name="verificata" required disabled={pending} className="mt-1" />Ho verificato che il documento sia già emesso e riguardi questo cliente e questo veicolo. Confermo il recupero dei dati fiscali e l’allineamento della pratica.</label>
      <button disabled={pending} className="rounded-lg bg-blue-700 px-4 py-2 text-sm font-bold text-white disabled:opacity-50">{pending ? 'Registrazione…' : 'Verifica documento e allinea pratica'}</button>
      {esito.messaggio && <p role="status" className={`text-sm font-semibold ${esito.ok ? 'text-green-800' : 'text-red-800'}`}>{esito.messaggio}</p>}
    </form>
  </details>;
}
