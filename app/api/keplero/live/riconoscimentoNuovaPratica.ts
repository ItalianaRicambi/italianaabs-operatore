type Payload = Record<string, unknown>;

export type RiconoscimentoNuovaPratica = {
  richiesta: boolean;
  fonte: "campo_strutturato" | "testo_esplicito" | "nessuna";
  evidenza: string;
};

const CAMPI_STRUTTURATI = [
  "nuova_pratica",
  "nuovo_veicolo",
  "altra_vettura",
  "new_case",
  "new_vehicle",
] as const;

const CAMPI_TESTO = [
  "ultimo_messaggio_cliente",
  "messaggio_cliente",
  "messaggio",
  "descrizione_guasto",
  "riepilogo_operativo",
  "richiesta",
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

  const valueNormalizzato = testo(value).toLowerCase();
  if (["1", "true", "vero", "si", "sì", "yes"].includes(valueNormalizzato)) {
    return true;
  }
  if (["0", "false", "falso", "no"].includes(valueNormalizzato)) {
    return false;
  }

  return null;
}

function normalizza(value: string) {
  return value
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/\s+/g, " ")
    .trim();
}

const PATTERN_NUOVO_VEICOLO = [
  /\b(?:un\s+)?(?:altra|seconda|nuova)\s+(?:auto|vettura|macchina|moto|centralina|abs)\b/i,
  /\b(?:un\s+)?(?:altro|secondo|nuovo)\s+(?:veicolo|mezzo|modulo|dispositivo)\b/i,
  /\b(?:dati|diagnosi|foto|codici|preventivo|richiesta)\b.{0,60}\b(?:altra|nuova)\s+(?:auto|vettura|macchina|moto)\b/i,
  /\bper\s+(?:un\s+)?(?:altra|nuova)\s+(?:auto|vettura|macchina|moto)\b/i,
  /\bnon\s+(?:e|è)\s+(?:la\s+)?stessa\s+(?:auto|vettura|macchina|moto)\b/i,
];

export function riconosciNuovaPratica(
  payload: Payload
): RiconoscimentoNuovaPratica {
  for (const campo of CAMPI_STRUTTURATI) {
    const valore = booleanoEsplicito(payload[campo]);
    if (valore === true) {
      return {
        richiesta: true,
        fonte: "campo_strutturato",
        evidenza: `${campo}=true`,
      };
    }
  }

  for (const campo of CAMPI_TESTO) {
    const valore = testo(payload[campo]);
    const valoreNormalizzato = normalizza(valore);
    if (
      valoreNormalizzato &&
      PATTERN_NUOVO_VEICOLO.some((pattern) => pattern.test(valoreNormalizzato))
    ) {
      return {
        richiesta: true,
        fonte: "testo_esplicito",
        evidenza: valore,
      };
    }
  }

  return {
    richiesta: false,
    fonte: "nessuna",
    evidenza: "",
  };
}
