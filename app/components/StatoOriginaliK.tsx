import Link from 'next/link';
import {rpcOriginaliK} from '../lib/originaliKepleroServer';
export type StatoOriginaliK = {automatico:boolean;elenco_at:string|null;errore_elenco:string|null;ultimo_tentativo:string|null;ultimo_successo:string|null;piu_vecchia:string|null;sessioni:number;errori:number;da_verificare:number;recuperate:number};
export async function StatoOriginaliK(){
 const stato=await rpcOriginaliK<StatoOriginaliK>('stato_originali_k').catch(()=>null);
 return <section className="mb-6 rounded-2xl border border-amber-200 bg-white p-5">
  <div className="flex flex-wrap items-center justify-between gap-3"><h2 className="text-lg font-bold">Conferme dalle chat originali K</h2><Link href="/keplero/originali" className="rounded-lg bg-slate-900 px-4 py-2 text-sm font-bold text-white">Apri verifiche{stato?` · ${stato.da_verificare}`:''}</Link></div>
  {stato?.automatico&&(!stato.ultimo_tentativo||Date.now()-Date.parse(stato.ultimo_tentativo)>900000)&&<p role="alert" className="mt-3 font-bold text-red-800">Controllo fermo: verificare il collegamento. Le conferme potrebbero essere ancora da acquisire.</p>}
  {stato?.errore_elenco&&<p role="alert" className="mt-3 font-bold text-red-800">Elenco conversazioni non aggiornato: copertura incompleta. {stato.errore_elenco}</p>}
  {stato?<p className="mt-3 text-sm">{stato.automatico?'Controllo periodico attivo anche durante la gestione manuale':'Controllo periodico sospeso'} · Conversazioni note: {stato.sessioni} · Conferme recuperate: {stato.recuperate} · Da verificare: <strong>{stato.da_verificare}</strong> · Errori: {stato.errori}<br/>Ultimo lotto completato: {stato.ultimo_successo?new Date(stato.ultimo_successo).toLocaleString('it-IT',{timeZone:'Europe/Rome'}):'da collaudare'}</p>:<p role="alert" className="mt-3 text-red-800">Registro originali non disponibile: verificare il collegamento K.</p>}
 </section>;
}
