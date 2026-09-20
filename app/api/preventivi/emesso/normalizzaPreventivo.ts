export type EventoPreventivoEmesso = {
  externalId: string;
  nomeFile: string;
  targa: string;
  fileUrl: string | null;
  dataOfferta: string;
  inviatoAt: string;
};

type Payload = Record<string, unknown>;

function testo(value: unknown) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function primo(payload: Payload, ...chiavi: string[]) {
  for (const chiave of chiavi) {
    const value = payload[chiave];
    if (testo(value)) return value;
  }
  return null;
}

export function normalizzaTargaPreventivo(value: unknown) {
  return testo(value)
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
}

function dataIso(value: unknown, campo: string) {
  const raw = testo(value);
  const data = raw ? new Date(raw) : new Date();

  if (Number.isNaN(data.getTime())) {
    throw new Error(`${campo} non valida`);
  }

  return data.toISOString();
}

export function normalizzaEventoPreventivo(
  payload: Payload
): EventoPreventivoEmesso {
  const externalId = testo(
    primo(payload, "external_id", "file_id", "drive_file_id")
  );
  const nomeFile = testo(primo(payload, "nome_file", "file_name"));
  const fileUrl = testo(primo(payload, "file_url", "link_file")) || null;

  if (!externalId || externalId.length > 255) {
    throw new Error("external_id mancante o non valido");
  }

  if (!/\.pdf$/i.test(nomeFile) || nomeFile.length > 255) {
    throw new Error("nome_file deve identificare un PDF");
  }

  const targaDaNome = normalizzaTargaPreventivo(
    nomeFile.replace(/\.pdf$/i, "")
  );
  const targaDichiarata = normalizzaTargaPreventivo(
    primo(payload, "targa", "plate")
  );

  if (!/^[A-Z0-9]{4,12}$/.test(targaDaNome)) {
    throw new Error("Il nome del PDF non contiene una targa valida");
  }

  if (targaDichiarata && targaDichiarata !== targaDaNome) {
    throw new Error("La targa dichiarata non coincide con il nome del PDF");
  }

  if (fileUrl) {
    let url: URL;
    try {
      url = new URL(fileUrl);
    } catch {
      throw new Error("file_url non valido");
    }

    if (url.protocol !== "https:") {
      throw new Error("file_url deve usare HTTPS");
    }
  }

  return {
    externalId,
    nomeFile,
    targa: targaDaNome,
    fileUrl,
    dataOfferta: dataIso(
      primo(payload, "data_offerta", "created_at", "data_creazione"),
      "data_offerta"
    ),
    inviatoAt: dataIso(
      primo(payload, "inviato_at", "sent_at"),
      "inviato_at"
    ),
  };
}
