'use client';

import { useActionState, useState } from 'react';
import { correggiSceltaCliente } from '../pratica/[id]/actions';
import { NOMI_SCELTA, type AlternativaOfferta, type OffertaVersione, type SceltaCliente } from '../lib/flussiOperativi';

const input = 'w-full rounded-lg border border-slate-300 bg-white p-2 text-sm';
const euro = (value: number) => new Intl.NumberFormat('it-IT', { style: 'currency', currency: 'EUR' }).format(value);

export function CorrezioneSceltaCliente({ praticaId, scelta, offerte, opzioni }: {
  praticaId: string; scelta: SceltaCliente | null; offerte: OffertaVersione[]; opzioni: AlternativaOfferta[];
}) {
  const [opzione, setOpzione] = useState(scelta?.opzione_id || '');
  const [stato, setStato] = useState(scelta?.stato === 'modifica_da_verificare' ? 'da_chiarire' : scelta?.stato || 'preferenza');
  const [nota, setNota] = useState('');
  const [esito, azione, pending] = useActionState(correggiSceltaCliente, { ok: false, messaggio: '' });
  const verificate = opzioni.filter(o => offerte.some(q => q.id === o.offerta_id && q.stato === 'letta'));

  return <form action={azione} className="mt-3 space-y-3">
    <input type="hidden" name="pratica_id" value={praticaId} />
    <label className="block text-sm">Alternativa del preventivo
      <select className={input} name="opzione_id" value={opzione} onChange={e => setOpzione(e.target.value)} disabled={pending}>
        <option value="">Soluzione da chiarire</option>
        {opzioni.map(o => <option key={o.id} value={o.id} disabled={!verificate.some(v => v.id === o.id)}>
          {o.servizio} · {euro(o.importo)} · versione {offerte.find(q => q.id === o.offerta_id)?.versione} · opzione {o.numero}
        </option>)}
      </select>
    </label>
    {!verificate.length && <p className="rounded-lg bg-amber-50 p-3 text-sm text-amber-950">Prima di confermare la scelta, apri «Leggi un PDF o registra le alternative» e registra le soluzioni del preventivo.</p>}
    <label className="block text-sm">Stato della scelta
      <select className={input} name="stato" value={stato} onChange={e => setStato(e.target.value)} disabled={pending}>
        {Object.entries(NOMI_SCELTA).filter(([k]) => k !== 'modifica_da_verificare').map(([k, v]) => <option key={k} value={k}>{v}</option>)}
      </select>
    </label>
    <label className="block text-sm">Frase del cliente o motivo della correzione
      <textarea className={input} name="nota" value={nota} onChange={e => setNota(e.target.value)} readOnly={pending} placeholder="Frase del cliente o motivo della correzione" required />
    </label>
    <p className="text-xs text-slate-500">La correzione viene tracciata e protetta. Lo stato dell’ordine si gestisce nella sezione commerciale.</p>
    <button disabled={pending} className="rounded-lg bg-slate-900 px-3 py-2 text-sm font-bold text-white disabled:opacity-50">{pending ? 'Salvataggio…' : 'Salva scelta verificata'}</button>
    {esito.messaggio && <p role="status" aria-live="polite" className={`rounded-lg p-3 text-sm font-semibold ${esito.ok ? 'bg-green-50 text-green-800' : 'bg-amber-50 text-amber-950'}`}>{esito.messaggio}</p>}
  </form>;
}
