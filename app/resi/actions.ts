'use server';
import {revalidatePath} from 'next/cache';
import {getOperatoreAttivo} from '../operatore';
import {rpcEmail} from '../lib/emailLogisticaServer';
import {redirect} from 'next/navigation';
const azioni=['presa','reso','accordo','assistenza','verifica','decaduta','comunicata','rettifica','attiva','montaggio','spedizione'];
export async function registraEsito(form:FormData) {
 const autore=await getOperatoreAttivo();
 if(!autore) redirect('/');
 const id=String(form.get('id')), revisione=Number(form.get('revisione')), tipo=String(form.get('tipo'));
 if(!/^[0-9a-f-]{36}$/i.test(id)||!Number.isSafeInteger(revisione)||!azioni.includes(tipo)) redirect('/resi?errore=1');
 const dati:Record<string,string>={};
 for(const k of ['data','nota','presa','canale','clausola','testo','prova']) {
  const valore=String(form.get(k)||'').trim();
  if(valore) dati[k]=valore.slice(0,8000);
 }
 try {
  await rpcEmail('evento_reso_scambio',{p_id:id,p_revisione:revisione,p_tipo:tipo,
   p_chiave:['operatore',revisione,tipo].join('/'),p_autore:autore,p_dati:dati});
 } catch {redirect('/resi?id='+id+'&errore=1');}
 revalidatePath('/resi'); revalidatePath('/'); revalidatePath('/pratica/[id]','page');
 redirect('/resi?id='+id);
}
