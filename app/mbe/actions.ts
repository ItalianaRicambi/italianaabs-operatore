'use server';
import {revalidatePath} from 'next/cache';
import {richiediOperatoreAttivo} from '../operatore';
import {rpcMbe,sincronizzaMbe} from '../lib/mbeServer';
import {ErroreMbe} from '../lib/mbe';
export type StatoAzioneMbe={errore:string|null;successo:string|null};
export async function collaudaMbe(_s:StatoAzioneMbe):Promise<StatoAzioneMbe> {
 void _s;
 await richiediOperatoreAttivo();
 try{const r=await sincronizzaMbe();revalidatePath('/mbe');return {errore:null,successo:`Lettura completata: ${r.importate} spedizioni importate, ${r.controllate} tracking controllati. È possibile attivare l’aggiornamento automatico.`};}
 catch(e){revalidatePath('/mbe');return {errore:e instanceof ErroreMbe?e.message:'Collaudo non riuscito. Riprovare.',successo:null};}
}
export async function cambiaAutomaticoMbe(_s:StatoAzioneMbe,dati:FormData):Promise<StatoAzioneMbe> {
 await richiediOperatoreAttivo();const attivo=dati.get('attivo')==='true';
 try{await rpcMbe('configura_automatico_mbe',{p_attivo:attivo});revalidatePath('/mbe');return {errore:null,successo:attivo?'Lettura automatica attiva: controllo ogni 15 minuti.':'Lettura automatica sospesa.'};}
 catch{return {errore:'Attivazione non riuscita. Eseguire prima un collaudo completo nelle ultime 24 ore.',successo:null};}
}
export async function classificaMbe(_s:StatoAzioneMbe,dati:FormData):Promise<StatoAzioneMbe> {
 const operatore=await richiediOperatoreAttivo();
 const tracking=String(dati.get('tracking')||''),tipo=String(dati.get('tipo')||'');
 if(!/^[A-Za-z0-9-]{1,20}$/.test(tracking)||!['cliente','laboratorio','rientro','da_classificare'].includes(tipo))return {errore:'Selezionare una destinazione valida.',successo:null};
 try{await rpcMbe('classifica_spedizione_mbe',{p_tracking:tracking,p_tipo:tipo,p_operatore:operatore});revalidatePath('/mbe');return {errore:null,successo:'Destinazione salvata.'};}
 catch{return {errore:'Destinazione non salvata. Riprovare.',successo:null};}
}
