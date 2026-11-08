import { prontaPerFatturazione, fatturazioneSospesa } from './fatturazione.ts';
import { sceltaClienteDaChiarire } from './flussiOperativi.ts';
import type { PraticaOggi } from './oggi.ts';

export function avvisoOrdine(p: PraticaOggi) {
  if (p.tipo_flusso !== 'commerciale' || p.stato_commerciale !== 'ordine_acquisito' || p.stato_fatturazione === 'fatturato') return null;
  const fic = p.dati_raw?.fic_anagrafica as { stato?: string } | undefined;
  if (fatturazioneSospesa(p) || p.blocco_operatore || p.offerta_da_verificare || sceltaClienteDaChiarire({...p,stato_fatturazione:p.stato_fatturazione || '',stato_commerciale:p.stato_commerciale || '',tipo_flusso:p.tipo_flusso || ''}))
    return { pronto: false, titolo: 'ORDINE ACCETTATO — VERIFICA OPERATORE', testo: 'È presente un blocco o una sospensione. Verificare prima di emettere fattura e proseguire la pratica.' };
  if (prontaPerFatturazione(p) && ['riconosciuto', 'nuovo'].includes(fic?.stato || ''))
    return { pronto: true, titolo: 'ORDINE ACCETTATO — EMETTERE FATTURA', testo: 'Dati fiscali disponibili e controllo Fatture in Cloud eseguito. Emettere la fattura e organizzare lo svolgimento della pratica.' };
  const testo = fic?.stato === 'riconosciuto' ? 'Cliente già presente in Fatture in Cloud: usare l’anagrafica esistente e verificare solo i dati mancanti o discordanti.'
    : fic?.stato === 'nuovo' ? 'Cliente non trovato con gli identificativi fiscali forniti: completare e verificare solo i dati mancanti della nuova anagrafica.'
    : fic?.stato === 'ambiguo' ? 'Più anagrafiche o dati discordanti: verificare l’intestatario prima di fatturare, senza chiedere nuovamente tutti i dati.'
    : fic?.stato === 'identita_mancante' ? 'Per riconoscere il cliente serve una partita IVA o un codice fiscale valido. Chiedere solo questo riferimento, conservando i dati già ricevuti.'
    : fic?.stato === 'errore' ? 'Controllo Fatture in Cloud non riuscito: verificare il collegamento. Il cliente non viene considerato nuovo.'
    : 'Controllo dell’anagrafica su Fatture in Cloud in attesa. Non richiedere nuovamente tutti i dati al cliente.';
  return { pronto: false, titolo: 'ORDINE ACCETTATO — COMPLETARE LA FATTURAZIONE', testo };
}
