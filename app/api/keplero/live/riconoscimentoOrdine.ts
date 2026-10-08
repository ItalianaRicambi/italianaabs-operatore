type PayloadKeplero = Record<string, unknown>;

export type RiconoscimentoOrdine = {
  confermato: boolean;
  fonte:
    | "campo_esplicito"
    | "messaggio_esplicito"
    | "riepilogo_esplicito"
    | "contesto_verificato"
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
  if (/\bprima di\b.{0,45}\b(proced|acquist|ordin)/.test(frase) &&
      /verific|confront|meccanic|elettraut|valut/.test(frase)) return true;
  return [
    /\b(devo|faccio|faro|prima)\b.{0,80}(passaggio|confront|verific|sentire).{0,60}(meccanic|elettraut)/,
    /\b(ne parlo|ne parlero|mi confronto|mi confrontero)\b.{0,35}(meccanic|elettraut)/,
    /\bappena (pronto|decido)\b.{0,60}(riferiment|conferm|acquist)/,
    /\bnon\b.{0,25}\b(accett|conferm|approv|proced)/,
    /\b(non va bene|rifiuto|rifiutiamo|troppo caro)\b/,
    /\b(ci penso|dobbiamo pensarci|devo valutare|dobbiamo valutare)\b/,
    /\b(vi faccio sapere|le faccio sapere|forse|eventualmente)\b/,
    /\bse\s+(accetto|accettiamo|confermo|confermiamo|approvo|approviamo|procedo|procediamo)\b/,
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
    if (valore === true) {
      return {
        confermato: true,
        fonte: "campo_esplicito",
        messaggio,
      };
    }
  }

  const confermaEsplicita = [
    /\b(accetto|accettiamo|confermo|confermiamo|approvo|approviamo)\b.{0,45}\b(preventivo|offerta|ordine)\b/,
    /\b(preventivo|offerta|ordine)\b.{0,45}\b(accettat[oa]|confermat[oa]|approvat[oa])\b/,
    /\b(potete|puo|puoi)\s+procedere\b/,
    /\bprocedete\s+pure\b/,
    /\bdate\s+pure\s+corso\b/,
    /\b(?:vorrei|voglio|intendiamo|intendo|desidero)\s+(?:dare\s+seguito|procedere|proseguire)\b/,
    /\b(?:dare|diamo|date)\s+seguito\b.{0,55}\b(?:preventivo|offerta|lavorazione|riparazione)\b/,
    /\b(?:procedere|proseguire)\b.{0,55}\b(?:preventivo|offerta|lavorazione|riparazione|programma\s+scambio)\b/,
    /\bordine\b.{0,80}\b(?:modificar|procedere|ritiro)\b/,
    /^(?:la\s+)?lavorazione\s+(?:elettronica\s+)?(?:del|dello|sul)\s+dispositivo[.! ]*$/,
    /\b(va bene|confermo)[, ]+.{0,25}\bprocedete\b/,
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
      /\bscelt[oa]\b.{0,55}\b(lavorazione|riparazione|programma\s+scambio)\b/,
      /\b(lavorazione|riparazione|programma\s+scambio)\b.{0,55}\bscelt[oa]\b/,
      /\b(?:dare\s+seguito|procedere|proseguire)\b.{0,55}\b(?:preventivo|offerta|lavorazione|riparazione|programma\s+scambio)\b/,
      /\bmodifica\b.{0,30}\bordine\b.{0,80}\b(?:procedere|ritiro)\b/,
    ].some((regola) => regola.test(fraseRiepilogo));

  return {
    confermato: confermaNelRiepilogo,
    fonte: confermaNelRiepilogo ? "riepilogo_esplicito" : "nessuna",
    messaggio: confermaNelRiepilogo ? riepilogo : messaggio,
  };
}
