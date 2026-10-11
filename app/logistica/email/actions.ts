'use server';
import { revalidatePath } from 'next/cache';
import { richiediOperatoreAttivo } from '../../operatore';
import { collaudaSmtpLogistica, rpcEmail } from '../../lib/emailLogisticaServer';

export type StatoConfigurazioneEmail = { errore: string | null; successo: string | null };

export async function configuraSmtpLogistica(_stato: StatoConfigurazioneEmail, dati: FormData): Promise<StatoConfigurazioneEmail> {
  const operatore = await richiediOperatoreAttivo();
  const password = String(dati.get('password') || '');
  if (!password || password.length > 1000) return { errore: 'Inserisci la password della casella spedizioni.', successo: null };
  try {
    const messageId = await collaudaSmtpLogistica(password);
    await rpcEmail('salva_smtp_logistica', { p_password: password, p_message_id: messageId, p_operatore: operatore });
    revalidatePath('/logistica/email');
    return { errore: null, successo: 'Prova inviata e collegamento salvato. Verifica la ricezione della mail di collaudo e attiva gli avvisi qui sotto.' };
  } catch { return { errore: 'Collaudo o salvataggio non riuscito. Controlla la password e riprova. Il collegamento non è stato aggiornato.', successo: null }; }
}

export async function cambiaInvioLogistica(_stato: StatoConfigurazioneEmail, dati: FormData): Promise<StatoConfigurazioneEmail> {
  const operatore = await richiediOperatoreAttivo();
  const abilita = dati.get('abilita') === 'true';
  if (abilita && dati.get('ricezione_confermata') !== 'on') return { errore: 'Conferma la ricezione della mail di collaudo.', successo: null };
  try {
    await rpcEmail('abilita_email_logistica', { p_abilitata: abilita, p_operatore: operatore });
    revalidatePath('/logistica/email');
    return { errore: null, successo: abilita ? 'Avvisi automatici attivati. Il servizio controlla la coda ogni 5 minuti.' : 'Avvisi automatici sospesi.' };
  } catch { return { errore: 'Operazione non riuscita. È richiesto un collaudo recente prima dell’attivazione.', successo: null }; }
}

export async function rivalutaAvvisoLogistica(dati: FormData) {
  const operatore = await richiediOperatoreAttivo();
  const id = String(dati.get('id') || '');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new Error('Avviso non valido.');
  await rpcEmail('rivaluta_email_logistica', { p_id: id, p_operatore: operatore });
  revalidatePath('/logistica/email');
}

export async function risolviAvvisoLogistica(_stato: StatoConfigurazioneEmail, dati: FormData): Promise<StatoConfigurazioneEmail> {
  const operatore = await richiediOperatoreAttivo();
  const id = String(dati.get('id') || '');
  const esito = String(dati.get('esito') || '');
  const evidenza = String(dati.get('evidenza') || '').trim();
  if (!/^[0-9a-f-]{36}$/i.test(id) || !['inviata', 'errore'].includes(esito) || evidenza.length < 20 || evidenza.length > 2000 || dati.get('verificato') !== 'on') return { errore: 'Indica l’esito e la prova del controllo presso il servizio di posta.', successo: null };
  try {
    await rpcEmail('risolvi_email_logistica', { p_id: id, p_esito: esito, p_evidenza: evidenza, p_operatore: operatore });
    revalidatePath('/logistica/email');
    return { errore: null, successo: 'Verifica registrata. Un eventuale nuovo tentativo richiede una rivalutazione separata.' };
  } catch { return { errore: 'Verifica non registrata. Controlla lo stato dell’avviso e riprova.', successo: null }; }
}
