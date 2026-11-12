import { labels, type Field, type Phase } from './policy.ts';

const technical = {
  targa: 'targa',
  codice_o_immagine_componente: 'foto',
  descrizione_guasto: 'guasto',
  dtc_con_spie_accese: 'diagnosi',
} as const satisfies Record<string, Field>;

const fiscal = {
  denominazione: 'denominazione',
  indirizzo_fatturazione: 'indirizzo_fatturazione',
  cap: 'cap',
  comune: 'comune',
  provincia: 'provincia',
  paese: 'nazione',
  nazione: 'nazione',
  partita_iva: 'partita_iva',
  codice_fiscale: 'codice_fiscale',
  partita_iva_o_codice_fiscale: 'partita_iva_o_codice_fiscale',
  pec: 'sdi_o_pec',
  codice_sdi: 'sdi_o_pec',
  sdi_o_pec: 'sdi_o_pec',
} as const satisfies Record<string, Field>;

export type InitialRequest = { phase: Phase; exactText: string; fields: Field[] };

export function prepareTechnicalRequest(reasons: readonly string[]): InitialRequest | null {
  // Lo stato spie si può chiedere nel flusso ordinario. Da solo non prova
  // che al cliente vada chiesta una diagnosi.
  if (reasons.some(reason => reason !== 'stato_spie' && !Object.hasOwn(technical, reason))) return null;
  const fields = [...new Set(reasons
    .filter((reason): reason is keyof typeof technical => Object.hasOwn(technical, reason))
    .map(reason => technical[reason]))];
  if (!fields.length) return null;
  return {
    phase: 'preventivo',
    exactText: `Per preparare il preventivo ci servono ancora: ${fields.map(field => labels[field]).join(', ')}. Può inviarceli qui?`,
    fields,
  };
}

export function technicalRequestFromNote(note: string | null): InitialRequest | null {
  const match = /^Dati mancanti: ([a-z_, ]+)\.$/u.exec(note ?? '');
  return match ? prepareTechnicalRequest(match[1].split(', ')) : null;
}

export function prepareFiscalRequest(text: string | null, reasons: readonly string[]): InitialRequest | null {
  if (!text?.startsWith("Grazie, abbiamo registrato l'accettazione del preventivo. Per preparare la fattura ci servono ancora: ")
    || !text.endsWith('. Può inviarceli qui?')
    || !reasons.length || !reasons.every(reason => Object.hasOwn(fiscal, reason))) return null;
  const fields = [...new Set(reasons.map(reason => fiscal[reason as keyof typeof fiscal]))];
  return { phase: 'fatturazione', exactText: text, fields };
}
