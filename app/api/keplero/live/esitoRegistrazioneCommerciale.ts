export type EsitoRegistrazioneCommerciale = {
  versione_contratto: string;
  pratica_id: string;
  numero_pratica: number;
  ricevuta: true;
  ordine_registrato: boolean;
  preventivo_inviato: boolean;
  stato_commerciale: string;
  stato_fatturazione: string;
  stato_amministrativo: string;
  lavoro_aperto: boolean;
  lavoro_id: string | null;
  versione_lavoro: number | null;
  requisiti: Record<string, unknown>;
  istruzione: string;
};

/** Il flag di riconoscimento non è una ricevuta di salvataggio. */
export function leggiEsitoRegistrazioneCommerciale(
  value: unknown,
  praticaAttesa: string
): EsitoRegistrazioneCommerciale {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Esito di registrazione non disponibile");
  }
  const r = value as Record<string, unknown>;
  if (
    r.versione_contratto !== "2026-10-23-esiti-v1" ||
    r.pratica_id !== praticaAttesa ||
    r.ricevuta !== true ||
    typeof r.ordine_registrato !== "boolean" ||
    typeof r.preventivo_inviato !== "boolean" ||
    typeof r.stato_commerciale !== "string" ||
    typeof r.stato_fatturazione !== "string" ||
    typeof r.istruzione !== "string" ||
    !r.istruzione.trim() ||
    r.ordine_registrato !== (r.stato_commerciale === "ordine_acquisito")
  ) {
    throw new Error("Esito di registrazione discordante");
  }
  return r as EsitoRegistrazioneCommerciale;
}
