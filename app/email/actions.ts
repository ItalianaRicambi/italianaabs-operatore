'use server';
import { revalidatePath } from 'next/cache';
import { getOperatoreAttivo } from '../operatore';
import { rpcEmail } from '../lib/emailLogisticaServer';
import { leggiRichiesteEmail, processaRichiestaEmail } from '../lib/richiesteEmailServer';
import { normalizzaEmail } from '../lib/richiesteEmail';
export async function riprovaEmail(form:FormData){
 if(!await getOperatoreAttivo()) throw new Error('Accesso richiesto');
 const id=String(form.get('id')||'');const e=(await leggiRichiesteEmail()).find(r=>r.id===id);
 if(!e || !['errore','in_elaborazione'].includes(e.stato)) return;
 await processaRichiestaEmail(normalizzaEmail(e));revalidatePath('/email');revalidatePath('/');
}
export async function gestitaEmail(form:FormData){
 const operatore=await getOperatoreAttivo();if(!operatore) throw new Error('Accesso richiesto');
 await rpcEmail('gestisci_richiesta_email',{p_id:String(form.get('id')||''),p_operatore:operatore});revalidatePath('/email');revalidatePath('/');
}
