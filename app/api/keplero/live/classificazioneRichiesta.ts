type Payload = Record<string, unknown>;

/** La garanzia richiesta prima dell'acquisto non prova un post vendita. */
export function classificaRichiesta(payload: Payload): "commerciale" | "assistenza" {
  const messaggio = String(payload.ultimo_messaggio_cliente || payload.messaggio_cliente || payload.messaggio || "").toLowerCase();
  const testo = `${messaggio} ${payload.descrizione_guasto || ""}`.toLowerCase();
  const acquistoPrecedente = /(?:ho|abbiamo)\s+(?:acquistato|ricevuto)|(?:ricevuto|fornito|riparato)\s+da\s+voi|vostr[oa]\s+(?:riparazione|intervento)/.test(testo);
  const problema = /problem|non\s+(?:riesc|funzion)|difett|codific|stess[oa].{0,20}(?:guasto|errore)/.test(testo);
  if (acquistoPrecedente && problema && !/non\s+(?:ho|abbiamo)\s+(?:acquistato|ricevuto)/.test(testo)) return "assistenza";
  if (/\b(?:vorrei|richiedo|richiedere|chiedo|avere)\b.{0,50}\bpreventivo\b|\b(?:ne avete|avreste).{0,35}(?:pronto|revisionato|disponibil)/.test(messaggio)) return "commerciale";
  const esplicito = String(payload.tipo_flusso || payload.flusso || payload.request_type || "").toLowerCase();
  if (esplicito === "commerciale" || esplicito === "assistenza") return esplicito;
  return /in garanzia|post[- ]?(?:vendita|riparazione|scambio)|problema dopo|rientro.{0,25}garanzia|assistenza tecnica/.test(testo)
    ? "assistenza" : "commerciale";
}
