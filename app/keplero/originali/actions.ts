'use server';
import {revalidatePath} from 'next/cache';
import {getOperatoreAttivo} from '../../operatore';
import {rpcOriginaliK} from '../../lib/originaliKepleroServer';
export async function archiviaOriginaleK(dati:FormData){
 const op=await getOperatoreAttivo();if(!op)throw new Error('Accesso richiesto');
 const sessione=String(dati.get('sessione')||''),messaggio=String(dati.get('messaggio')||'');
 if(!/^[0-9a-f-]{36}$/i.test(sessione)||!/^\w[\w-]{0,99}$/.test(messaggio))throw new Error('Riferimento non valido');
 await rpcOriginaliK('archivia_verifica_originale_k',{p_sessione:sessione,p_messaggio_id:messaggio,p_operatore:op});
 revalidatePath('/keplero/originali');revalidatePath('/');
}
