'use client';
import { useActionState, useState } from 'react';
import { creaECollegaClientePraticaOperatore } from '../pratica/[id]/actions';
import type { DatiFiscaliBozza } from '../lib/datiFiscaliChat';

const campi = [
  ['denominazione', 'Denominazione', true], ['indirizzo_fatturazione', 'Indirizzo di fatturazione', true],
  ['comune', 'Comune', true], ['cap', 'CAP', true], ['provincia', 'Provincia', false], ['paese', 'Paese', true],
  ['partita_iva', 'Partita IVA', false], ['codice_fiscale', 'Codice fiscale', false], ['email', 'Email', false],
  ['telefono', 'Telefono', false], ['pec', 'PEC', false], ['codice_sdi', 'Codice SDI', false],
] as const;
export function AnagraficaFiscale({ praticaId, iniziali }: { praticaId: string; iniziali: DatiFiscaliBozza }) {
  const [dati, setDati] = useState(iniziali);
  const [esito, azione, pending] = useActionState(creaECollegaClientePraticaOperatore, { ok: false, messaggio: '' });
  return <form action={azione} className="mt-4 grid gap-3">
    <input type="hidden" name="pratica_id" value={praticaId} />
    {campi.map(([name, label, required]) => <label key={name} className="block text-xs font-semibold text-slate-600">{label}{required ? ' *' : ''}
      <input name={name} required={required} readOnly={pending} value={dati[name] || ''} onChange={e => setDati({ ...dati, [name]: e.target.value })}
        type={name === 'email' || name === 'pec' ? 'email' : 'text'} maxLength={name === 'paese' ? 2 : 320}
        className="mt-1 w-full rounded-lg border border-slate-300 px-3 py-2 text-sm text-slate-950" />
    </label>)}
    <label className="flex items-start gap-2 text-xs"><input type="checkbox" name="verificata" required disabled={pending} className="mt-1" />Ho verificato l’intestatario, l’indirizzo e l’identificativo fiscale. Confermo questi dati e riabilito la fatturazione.</label>
    <button disabled={pending} className="rounded-lg bg-blue-600 px-4 py-2.5 text-sm font-bold text-white disabled:opacity-50">{pending ? 'Salvataggio…' : 'Conferma dati e collega cliente'}</button>
    {esito.messaggio && <p role="status" className={`text-sm font-semibold ${esito.ok ? 'text-green-800' : 'text-red-800'}`}>{esito.messaggio}</p>}
  </form>;
}
