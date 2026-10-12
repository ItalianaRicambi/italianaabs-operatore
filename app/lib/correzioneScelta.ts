export type EsitoCorrezioneScelta = { ok: boolean; messaggio: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STATI = new Set(['preferenza', 'condizionata', 'confermata', 'da_chiarire', 'revocata']);
const ALTERNATIVA_RICHIESTA = 'Per confermare la scelta, seleziona un’alternativa verificata del preventivo. Se manca, registra prima le alternative dal PDF.';

export async function salvaCorrezioneScelta(
  formData: FormData,
  operatore: string,
  esegui: (dati: Record<string, unknown>) => Promise<unknown>,
): Promise<EsitoCorrezioneScelta> {
  const praticaId = String(formData.get('pratica_id') || '');
  const opzioneId = String(formData.get('opzione_id') || '');
  const stato = String(formData.get('stato') || '');
  const nota = String(formData.get('nota') || '').trim();
  if (!UUID.test(praticaId) || (opzioneId && !UUID.test(opzioneId))) {
    return { ok: false, messaggio: 'Identificativo non valido. Ricarica la pratica e riprova.' };
  }
  if (!STATI.has(stato) || !nota) {
    return { ok: false, messaggio: 'Seleziona lo stato e inserisci la frase del cliente o il motivo della correzione.' };
  }
  if (stato === 'confermata' && !opzioneId) return { ok: false, messaggio: ALTERNATIVA_RICHIESTA };
  try {
    const risultato = await esegui({ p_pratica_id: praticaId, p_opzione_id: opzioneId || null,
      p_stato: stato, p_nota: nota, p_operatore: operatore });
    if (!risultato || typeof risultato !== 'object' || !('ok' in risultato) || risultato.ok !== true) {
      return { ok: false, messaggio: 'Salvataggio non confermato. Ricarica la pratica per verificare la scelta registrata.' };
    }
    return { ok: true, messaggio: 'Scelta salvata e protetta dagli aggiornamenti automatici.' };
  } catch (errore) {
    if (errore instanceof Error && errore.message.includes('Selezionare una alternativa verificata')) {
      return { ok: false, messaggio: ALTERNATIVA_RICHIESTA };
    }
    return { ok: false, messaggio: 'Salvataggio non riuscito. Verifica l’alternativa e riprova; il testo inserito è conservato.' };
  }
}
