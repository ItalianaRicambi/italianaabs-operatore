'use server';
import { richiediOperatoreAttivo } from '../../operatore';
import { sincronizzaFic } from '../../lib/ficRegistroServer';
import { validaRicercaFic, ErroreFic } from '../../lib/fattureInCloud';
import { revalidatePath } from 'next/cache';
export async function sincronizzaRegistroFic(_state: { messaggio: string; ok: boolean }, form: FormData) {
  await richiediOperatoreAttivo();
  try {
    const f = validaRicercaFic({tipo: form.get('tipo'), dal: form.get('dal'), al: form.get('al')});
    const r = await sincronizzaFic(f.tipo, f.dal, f.al);
    revalidatePath('/fatture-in-cloud/registro');
    return { ok: true, messaggio: `${r.documenti} documenti sincronizzati. ${r.non_rilevati} documenti precedenti da ricontrollare. Gli stati delle pratiche non sono stati modificati.` };
  } catch(e) {
    return { ok: false, messaggio: e instanceof ErroreFic ? e.message : 'Sincronizzazione non confermata. Ricarica il registro; se necessario riprova con un periodo più breve.' };
  }
}
