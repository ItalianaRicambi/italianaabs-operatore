'use client';
import {useActionState} from 'react';
import {collaudaMbe,cambiaAutomaticoMbe,classificaMbe,type StatoAzioneMbe} from './actions';
const INIZIO:StatoAzioneMbe={errore:null,successo:null};
function Esito({stato}:{stato:StatoAzioneMbe}) {return <>{stato.errore&&<p role="alert" className="mt-3 text-red-800">{stato.errore}</p>}{stato.successo&&<p role="status" className="mt-3 text-green-800">{stato.successo}</p>}</>;}
export function ComandiMbe({automatico,collaudato}:{automatico:boolean;collaudato:boolean}) {
 const [test,azioneTest,inTest]=useActionState(collaudaMbe,INIZIO);
 const [auto,azioneAuto,inAuto]=useActionState(cambiaAutomaticoMbe,INIZIO);
 return <div className="mt-5 space-y-4">
 <form action={azioneTest}><button disabled={inTest||inAuto} className="rounded-lg bg-blue-800 px-4 py-3 font-bold text-white disabled:opacity-50">{inTest?'Lettura MBE in corso…':'Verifica collegamento e sincronizza'}</button><Esito stato={test}/></form>
 <form action={azioneAuto}><input type="hidden" name="attivo" value={String(!automatico)}/><button disabled={inTest||inAuto||(!automatico&&!collaudato&&!test.successo)} className="rounded-lg border border-blue-800 px-4 py-2 font-semibold text-blue-900 disabled:opacity-50">{inAuto?'Salvataggio…':automatico?'Sospendi aggiornamento automatico':'Attiva aggiornamento ogni 15 minuti'}</button><Esito stato={auto}/></form>
 </div>;
}
export function ClassificaMbe({tracking,tipo}:{tracking:string;tipo:string}) {
 const [stato,azione,inCorso]=useActionState(classificaMbe,INIZIO);
 return <form action={azione} className="mt-4"><input type="hidden" name="tracking" value={tracking}/><label className="font-semibold">Destinazione <select name="tipo" defaultValue={tipo} className="rounded border bg-white p-2" aria-label={`Destinazione ${tracking}`}><option value="da_classificare">Da classificare</option><option value="cliente">Cliente</option><option value="laboratorio">Laboratorio</option><option value="rientro">Rientro</option></select></label><button disabled={inCorso} className="ml-2 rounded border px-3 py-2 font-semibold disabled:opacity-50">{inCorso?'Salvataggio…':'Salva destinazione'}</button><Esito stato={stato}/></form>;
}
