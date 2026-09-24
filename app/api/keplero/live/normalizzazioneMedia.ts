type Body = Record<string, unknown>;

const CAMPI_CODICI_ESPLICITI = [
  "codici_identificativi",
  "codici",
  "device_codes",
  "codice_identificativo",
  "codice_centralina",
  "numero_hardware",
  "hardware_number",
  "part_number",
  "part_numbers",
];

const CAMPI_TESTO_OCR = [
  "ocr_text",
  "testo_ocr",
  "image_text",
  "testo_immagini",
  "lettura_immagini",
  "codici_ocr",
  "ocr_codes",
  "codici_estratti",
];

function testo(value: unknown) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function valoriScalari(value: unknown): string[] {
  if (Array.isArray(value)) {
    return value.flatMap(valoriScalari);
  }

  if (value && typeof value === "object") {
    return Object.values(value).flatMap(valoriScalari);
  }

  const valueText = testo(value);
  return valueText ? [valueText] : [];
}

export function listaValori(value: unknown) {
  if (Array.isArray(value)) {
    return value.flatMap(valoriScalari).filter(Boolean);
  }

  const raw = testo(value);

  if (!raw) return [];

  return raw
    .split(/\r?\n|;|\||,/g)
    .map((item) => item.trim())
    .filter(Boolean);
}

export function normalizzaCodice(value: string) {
  return value
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
}

function estraiCodiciDaTesto(value: string) {
  const testoMaiuscolo = value.toUpperCase();
  const candidati = [
    ...(testoMaiuscolo.match(
      /\b(?=[A-Z0-9]{7,24}\b)(?=[A-Z0-9]*[A-Z])(?=[A-Z0-9]*\d)[A-Z0-9]+\b/g
    ) || []),
    ...(testoMaiuscolo.match(
      /\b(?=[A-Z0-9.-]{7,35}\b)(?=[A-Z0-9.-]*\d)[A-Z0-9]+(?:[.-][A-Z0-9]+)+\b/g
    ) || []),
    ...(testoMaiuscolo.match(
      /\b[A-Z0-9]{1,4}(?:\s+[A-Z0-9]{2,4}){2,5}\b/g
    ) || []),
  ];

  return candidati
    .map((item) => item.replace(/\s+/g, " ").trim())
    .filter((item) => normalizzaCodice(item).length >= 7);
}

export function estraiCodiciIdentificativi(
  body: Body,
  esclusioni: string[] = []
) {
  const espliciti = CAMPI_CODICI_ESPLICITI.flatMap((key) =>
    listaValori(body[key])
  );

  const estrattiOcr = CAMPI_TESTO_OCR.flatMap((key) =>
    valoriScalari(body[key]).flatMap(estraiCodiciDaTesto)
  );

  const esclusi = new Set(
    esclusioni.map(normalizzaCodice).filter(Boolean)
  );
  const visti = new Set<string>();

  return [...espliciti, ...estrattiOcr].filter((codice) => {
    const normalizzato = normalizzaCodice(codice);

    if (
      normalizzato.length < 4 ||
      esclusi.has(normalizzato) ||
      visti.has(normalizzato)
    ) {
      return false;
    }

    visti.add(normalizzato);
    return true;
  });
}

function estraiUrl(value: string) {
  return value.match(/https?:\/\/[^\s<>"']+/gi) || [];
}

export function normalizzaAllegati(value: unknown) {
  const valori = listaValori(value);
  const urls: string[] = [];
  const descrizioni: string[] = [];
  const viste = new Set<string>();

  for (const item of valori) {
    const trovati = estraiUrl(item);

    if (trovati.length === 0) {
      descrizioni.push(item);
      continue;
    }

    for (const url of trovati) {
      if (!viste.has(url)) {
        viste.add(url);
        urls.push(url);
      }
    }
  }

  return { urls, descrizioni };
}

export function statoLetturaImmagini(
  numeroCodici: number,
  numeroUrl: number,
  numeroDescrizioni: number
) {
  if (numeroCodici > 0) return "codici_acquisiti";
  if (numeroUrl > 0) return "file_ricevuti_senza_codici";
  if (numeroDescrizioni > 0) return "file_non_trasmessi_da_keplero";
  return "nessun_allegato";
}
