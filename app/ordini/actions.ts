'use server';
import { revalidatePath } from 'next/cache';
import { getOperatoreAttivo } from '../operatore';
import { rpcEmail } from '../lib/emailLogisticaServer';
export async function aggiornaEvasione(_stato: { errore: string; ok: boolean }, form: FormData) {
 const operatore = await getOperatoreAttivo();
 if (!operatore) return {errore:'Selezionare un operatore autenticato.',ok:false};
 const id = String(form.get('id') || ''), nota = String(form.get('nota') || '').trim(), tipo = String(form.get('tipo') || '');
 if (!/^[0-9a-f-]{36}$/i.test(id) || nota.length<12 || nota.length>2000) return {errore:'Inserire una prova o motivazione di almeno 12 caratteri.',ok:false};
 try {
  if (tipo === 'verifica') await rpcEmail('risolvi_verifica_acquisizione',{p_id:id,p_nota:nota,p_operatore:operatore});
  else if (tipo === 'evasione') {
   const revisione = Number(form.get('revisione')), stato = String(form.get('stato') || '');
   if (!Number.isSafeInteger(revisione) || revisione<1 || !['da_evadere','evaso','da_verificare'].includes(stato)) return {errore:'Dati non validi. Aggiornare la pagina.',ok:false};
   await rpcEmail('aggiorna_evasione_pratica',{p_pratica_id:id,p_revisione:revisione,p_stato:stato,p_nota:nota,p_operatore:operatore});
  } else return {errore:'Operazione non valida.',ok:false};
 } catch { return {errore:'Modifica non registrata: aggiornare la pagina e verificare stato, collegamento Shopify e revisione. Nessuna modifica alla fatturazione.',ok:false}; }
 revalidatePath('/'); revalidatePath('/ordini');
 return {errore:'',ok:true};
}
