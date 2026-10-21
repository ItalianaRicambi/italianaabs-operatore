import Link from 'next/link';
import {rpcOriginaliK} from '../lib/originaliKepleroServer';
export type ControlloRisposteK={inizio:string;recenti:number;incomplete:number;totale:number;stato:{automatico:boolean;elenco_at:string|null;errore_elenco:string|null;ultimo_tentativo:string|null};chat:{sessione:string;messaggio_id:string;data_messaggio:string;testo:string;assistente:string|null;motivo:string;pratica_id:string|null;nome_cliente:string|null;telefono:string|null;numero_pratica:number|null}[];esterne:{id:string;nome:string;telefono:string;testo:string;data_messaggio:string;fonte:string;nota:string}[];errori:{sessione:string;attivita_at:string;errore:string}[]};
export async function StatoRisposteK(){
 const s=await rpcOriginaliK<ControlloRisposteK>('controllo_risposte_k').catch(()=>null);
 const incompleta=!s||!s.stato.automatico||s.incomplete>0||s.stato.errore_elenco||!s.stato.elenco_at||Date.now()-Date.parse(s.stato.elenco_at)>900000||!s.stato.ultimo_tentativo||Date.now()-Date.parse(s.stato.ultimo_tentativo)>900000;
 return <section className="mb-6 rounded-2xl border border-red-200 bg-white p-5">
 <div className="flex flex-wrap items-center justify-between gap-3"><h2 className="text-lg font-bold">Clienti in attesa di risposta</h2><Link href="/keplero/risposte" className="rounded-lg bg-red-800 px-4 py-2 text-sm font-bold text-white">Controlla chat{s?` · ${s.totale+s.esterne.length}`:''}</Link></div>
 <p className="mt-3 text-sm">{s?`${s.totale} chat senza risposta verificabile da almeno 15 minuti · ${s.esterne.length} segnalazioni esterne aperte.`:'Controllo non disponibile.'}</p>
 {incompleta&&<p role="alert" className="mt-2 font-bold text-red-800">Verifica incompleta: {s?.incomplete??'?'} conversazioni recenti ancora da acquisire o con errori. Anche le chat assenti da K vanno confrontate con WhatsApp.</p>}
 <p className="mt-2 text-xs text-slate-600">Finestra: ultime 48 ore, escluso il fine settimana. Il controllo verifica i messaggi disponibili in K; non può vedere automaticamente quelli mai ricevuti dal servizio.</p>
 </section>;
}
