import type { RiconoscimentoOrdine } from "./riconoscimentoOrdine.ts";

/** Usa soltanto il contesto verificato nel database sulla pratica corrente. */
export function leggiOrdineContestuale(value: unknown): {
  riconoscimento: RiconoscimentoOrdine;
  avanzamento: Record<string, unknown>;
} | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const esito = value as Record<string, unknown>;
  const contesto = esito.contesto as Record<string, unknown> | undefined;
  const avanzamento = esito.avanzamento as Record<string, unknown> | undefined;
  if (esito.confermato !== true || esito.stato_commerciale !== "ordine_acquisito" ||
      !["da_fatturare", "fatturato"].includes(String(esito.stato_fatturazione)) ||
      !contesto || contesto.confermato !== true ||
      !["scelta_lavorazione_e_dati_fiscali_v1", "intenzione_offerta_e_dati_fiscali_v1", "conferma_letterale_offerta_v1"].includes(String(contesto.regola)) ||
      !avanzamento || typeof avanzamento !== "object" || Array.isArray(avanzamento)) return null;
  return {
    riconoscimento: {
      confermato: true,
      fonte: "contesto_verificato",
      messaggio: typeof esito.messaggio === "string" ? esito.messaggio : "",
    },
    avanzamento,
  };
}
