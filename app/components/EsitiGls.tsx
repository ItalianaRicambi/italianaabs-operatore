import Link from 'next/link';
import { NOMI_ABBINAMENTO_GLS, NOMI_ESITO_GLS, codiceGls, statoGlsAttuale, type EsitoGls } from '../lib/esitiGls';
import { dataPresaIt } from '../lib/prenotazioniPrese';
export function EsitoGlsCard({ esito }: { esito: EsitoGls }) {
 const stato = statoGlsAttuale(esito);
 const colore = stato === 'effettuata' ? 'border-green-300 bg-green-50' : stato === 'prenotata' ? 'border-blue-200 bg-blue-50' : 'border-amber-300 bg-amber-50';
 return <article className={`rounded-xl border p-4 ${colore}`}>
  <div className="flex flex-wrap items-center justify-between gap-2">
   <h3 className="font-bold">{codiceGls(esito.riferimento)} · {NOMI_ESITO_GLS[stato]}</h3>
   {esito.pratica_id && <Link className="font-bold text-blue-800 underline" href={`/pratica/${esito.pratica_id}`}>Apri {esito.numero_pratica ? `ABS-${String(esito.numero_pratica).padStart(6, '0')}` : 'pratica'}{esito.targa ? ` · ${esito.targa}` : ''}</Link>}
  </div>
  <p className="mt-2 text-sm">Data prevista: <strong>{dataPresaIt(esito.data_ritiro)}</strong> · Destinazione: <strong>{esito.destinazione}</strong></p>
  <p className="mt-1 text-sm">{esito.mittente} → {esito.destinatario}</p>
  {esito.motivo && <p className="mt-2 text-sm font-semibold">Ultimo evento di ritiro: {esito.motivo}</p>}
  {esito.numero_spedizione && <p className="mt-1 text-sm">Spedizione associata: {esito.numero_spedizione}</p>}
  <p className="mt-2 text-xs text-slate-600">Ultimo controllo: {new Date(esito.verificata_at).toLocaleString('it-IT', { timeZone: 'Europe/Rome' })} · {esito.fonte === 'api_gls' ? 'Servizio GLS' : 'Portale GLS'}</p>
  {esito.esito_abbinamento !== 'abbinata' && <p className="mt-2 text-sm font-bold text-amber-950">{NOMI_ABBINAMENTO_GLS[esito.esito_abbinamento] || 'Abbinamento da verificare'}</p>}
  <details className="mt-3 text-sm"><summary className="cursor-pointer font-semibold">Storico eventi GLS</summary>
   <div className="mt-2 overflow-x-auto"><table className="w-full text-left text-xs"><thead><tr><th className="p-2">Data e ora</th><th className="p-2">Luogo</th><th className="p-2">Stato GLS</th><th className="p-2">Note</th></tr></thead>
    <tbody>{[...esito.eventi].sort((a, b) => b.at.localeCompare(a.at)).map((e, i) => <tr key={i} className="border-t border-slate-200"><td className="p-2 whitespace-nowrap">{new Date(e.at).toLocaleString('it-IT', { timeZone: 'Europe/Rome' })}</td><td className="p-2">{e.luogo}</td><td className="p-2">{e.stato}</td><td className="p-2">{e.note}</td></tr>)}</tbody>
   </table></div>
  </details>
 </article>;
}
