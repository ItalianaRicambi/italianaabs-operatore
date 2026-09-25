type PayloadKeplero = Record<string, unknown>;

export type RiconoscimentoOrdine = {
  confermato: boolean;
  fonte:
    | "campo_esplicito"
    | "messaggio_esplicito"
    | "riepilogo_esplicito"
    | "nessuna";
  messaggio: string;
};

const CAMPI_ESPLICITI = [
  "preventivo_accettato",
  "accettazione_preventivo",
  "ordine_confermato",
  "conferma_ordine",
] as const;

function testo(value: unknown) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function booleanoEsplicito(value: unknown): boolean | null {
  if (typeof value === "boolean") return value;
  if (typeof value === "number") {
    if (value === 1) return true;
    if (value === 0) return false;
  }

  const normalizzato = testo(value).toLowerCase();
  if (["true", "1", "si", "sì", "yes", "vero"].includes(normalizzato)) {
    return true;
  }
  if (["false", "0", "no", "falso"].includes(normalizzato)) {
    return false;
  }

  return null;
}

function normalizzaFrase(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[’`]/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

function contieneNegazioneODubbio(frase: string) {
  return [
    /\?/,
    /\bnon\b.{0,25}\b(accett|conferm|approv|proced)/,
    /\b(non va bene|rifiuto|rifiutiamo|troppo caro)\b/,
    /\b(ci penso|dobbiamo pensarci|devo valutare|dobbiamo valutare)\b/,
    /\b(vi faccio sapere|le faccio sapere|forse|eventualmente)\b/,
    /\bse\s+(accetto|confermo|procedo|procediamo)\b/,
  ].some((regola) => regola.test(frase));
}

export function riconosciConfermaOrdine(
  payload: PayloadKeplero
): RiconoscimentoOrdine {
  const messaggio = testo(
    payload.ultimo_messaggio_cliente ??
      payload.messaggio_cliente ??
      payload.messaggio
  );
  const riepilogo = testo(
    payload.riepilogo_operativo ??
      payload.descrizione_guasto ??
      payload.richiesta
  );

  const frase = normalizzaFrase(messaggio);
  const fraseRiepilogo = normalizzaFrase(riepilogo);
  const dubbiaONegativa = contieneNegazioneODubbio(frase);

  if (dubbiaONegativa) {
    return { confermato: false, fonte: "nessuna", messaggio };
  }

  for (const campo of CAMPI_ESPLICITI) {
    if (!(campo in payload)) continue;

    const valore = booleanoEsplicito(payload[campo]);
    if (valore !== null) {
      return {
        confermato: valore,
        fonte: valore ? "campo_esplicito" : "nessuna",
        messaggio,
      };
    }
  }

  if (!frase) {
    return { confermato: false, fonte: "nessuna", messaggio };
  }

  const confermaEsplicita = [
    /\b(accetto|confermo|approvo)\b.{0,45}\b(preventivo|offerta|ordine)\b/,
    /\b(preventivo|offerta|ordine)\b.{0,45}\b(accettat[oa]|confermat[oa]|approvat[oa])\b/,
    /\b(potete|puo|puoi)\s+procedere\b/,
    /\bprocedete\s+pure\b/,
    /\bdate\s+pure\s+corso\b/,
    /\b(va bene|confermo)[, ]+.{0,25}\bprocedete\b/,
    /\bpagamento\s+(effettuato|eseguito|fatto)\b/,
    /\bho\s+(effettuato|eseguito|fatto)\s+il\s+pagamento\b/,
  ].some((regola) => regola.test(frase));

  if (confermaEsplicita) {
    return {
      confermato: true,
      fonte: "messaggio_esplicito",
      messaggio,
    };
  }

  const confermaNelRiepilogo =
    Boolean(fraseRiepilogo) &&
    !contieneNegazioneODubbio(fraseRiepilogo) &&
    [
      /\b(accettat[oa]|confermat[oa]|approvat[oa])\b.{0,55}\b(lavorazione|riparazione|preventivo|offerta|ordine)\b/,
      /\b(lavorazione|riparazione|preventivo|offerta|ordine)\b.{0,55}\b(accettat[oa]|confermat[oa]|approvat[oa])\b/,
      /\bconferma\s+(?:dell[' ]|l[' ])?ordine\b/,
    ].some((regola) => regola.test(fraseRiepilogo));

  return {
    confermato: confermaNelRiepilogo,
    fonte: confermaNelRiepilogo ? "riepilogo_esplicito" : "nessuna",
    messaggio: confermaNelRiepilogo ? riepilogo : messaggio,
  };
}
