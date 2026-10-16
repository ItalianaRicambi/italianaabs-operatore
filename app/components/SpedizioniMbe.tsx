import Link from 'next/link';
import type {RigaMbe} from '../lib/mbeServer';
import {NOMI_STATI_MBE} from '../lib/mbe';
import {ClassificaMbe} from '../mbe/ComandiMbe';
export function SpedizioniMbe({righe,classificabile=false}:{righe:RigaMbe[];classificabile?:boolean}) {
 if(!righe.length)return <p className="mt-4">Nessuna spedizione MBE acquisita{classificabile?'': ' collegata a questa pratica'}.</p>;
 return <div className="mt-4 space-y-4">{righe.map(r=><article key={r.tracking_mbe} className="rounded-xl border bg-white p-4">
 <h3 className="font-bold">MBE {r.tracking_mbe} · {r.stato?NOMI_STATI_MBE[r.stato]:'Tracking da verificare'}</h3>
 <p className="mt-2">Riferimento: {r.riferimento||'Assente'}{r.pratica_id&&<> · <Link className="text-blue-800 underline" href={`/pratica/${r.pratica_id}`}>Apri pratica</Link></>}</p>
 <p className={r.abbinamento==='abbinata'?'text-green-800':'text-amber-800'}>{r.motivo}</p>
 <p className="mt-2">Da: {r.mittente.nome||'Non indicato'} · {r.mittente.citta} {r.mittente.paese}<br/>A: {r.destinatario.nome||'Non indicato'} · {r.destinatario.citta} {r.destinatario.paese}</p>
 <p className="mt-2">Data registrazione MBE: {r.data_spedizione}{r.bozza===true?' · Da chiudere in MBE':''}{r.data_consegna&&<> · Consegna dichiarata da MBE: {r.data_consegna}</>}</p>
 <p>Corriere: {r.corriere||'Non indicato'} · Tracking corriere: {r.tracking_corriere||'Non disponibile'}</p>
 {r.tracking_corriere_stato&&r.tracking_corriere_stato!==r.tracking_corriere&&<p>Codice dal servizio tracking MBE: {r.tracking_corriere_stato}</p>}
 {r.descrizione&&<p className="mt-2">{r.descrizione}</p>}
 <p className="mt-2 text-sm text-slate-600">Ultima lettura: {new Date(r.ultima_lettura_at).toLocaleString('it-IT',{timeZone:'Europe/Rome'})} · Destinazione: {r.tipo_destinazione.replaceAll('_',' ')}</p>
 {classificabile&&<ClassificaMbe tracking={r.tracking_mbe} tipo={r.tipo_destinazione}/>}
 </article>)}</div>;
}
