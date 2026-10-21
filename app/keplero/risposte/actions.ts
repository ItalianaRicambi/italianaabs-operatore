'use server';
import {revalidatePath} from 'next/cache';
import {getOperatoreAttivo} from '../../operatore';
import {rpcOriginaliK} from '../../lib/originaliKepleroServer';
export async function verificaRispostaK(dati:FormData){
 const op=await getOperatoreAttivo();if(!op)throw new Error('Accesso richiesto');
 const sessione=String(dati.get('sessione')||''),id=String(dati.get('messaggio')||''),motivo=String(dati.get('motivo')||'').trim();
 if(!/^[0-9a-f-]{36}$/i.test(sessione)||!/^\w[\w-]{0,99}$/.test(id)||motivo.length<5||motivo.length>1000)throw new Error('Riferimento o motivo non valido');
 await rpcOriginaliK('verifica_risposta_k',{p_sessione:sessione,p_messaggio_id:id,p_motivo:motivo,p_operatore:op});
 revalidatePath('/keplero/risposte');revalidatePath('/');
}
