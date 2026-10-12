export const CAMPI_DATI_PRATICA = [
  "targa", "marca_veicolo", "modello_veicolo", "tipo_componente", "tipo_guasto", "descrizione_guasto",
] as const;

export type DatiPraticaModificabili = Record<typeof CAMPI_DATI_PRATICA[number], string>;
export type EsitoSalvataggioDati = {
  ok: boolean;
  messaggio: string;
  dati?: DatiPraticaModificabili;
};

export function leggiDatiModificabili(pratica: Record<string, unknown>): DatiPraticaModificabili {
  return Object.fromEntries(CAMPI_DATI_PRATICA.map(campo => [campo, String(pratica[campo] ?? "")])) as DatiPraticaModificabili;
}

export async function salvaEVerificaDatiPratica(
  formData: FormData,
  aggiorna: (dati: FormData) => Promise<void>,
  leggi: (id: string) => Promise<Record<string, unknown>>,
): Promise<EsitoSalvataggioDati> {
  try {
    await aggiorna(formData);
  } catch {
    return { ok: false, messaggio: "Salvataggio non riuscito. Le modifiche restano nei campi: riprova o verifica l’accesso operatore." };
  }
  try {
    const dati = leggiDatiModificabili(await leggi(String(formData.get("pratica_id") || "").trim()));
    // La RPC conserva i valori esistenti quando un campo viene lasciato vuoto.
    // Per i valori inviati, verifichiamo che non siano stati bloccati o modificati.
    const coerenti = CAMPI_DATI_PRATICA.every(campo => {
      const inviato = String(formData.get(campo) ?? "").trim();
      return !inviato || dati[campo] === (campo === "targa" ? inviato.toUpperCase() : inviato);
    });
    if (!coerenti) return { ok: false, messaggio: "I dati riletti non coincidono con le modifiche inviate. Verifica eventuali blocchi della pratica prima di uscire." };
    return { ok: true, dati, messaggio: "Dati salvati e confermati. Puoi tornare all’elenco." };
  } catch {
    return { ok: false, messaggio: "Richiesta inviata, ma non è stato possibile verificare il salvataggio. Le modifiche restano nei campi: riprova prima di uscire." };
  }
}
