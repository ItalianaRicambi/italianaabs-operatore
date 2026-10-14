type Payload = Record<string, unknown>;

/** Un esito esplicito chiude una domanda; non inventa lo stato delle spie. */
export function diagnosiSenzaErroriDichiarata(payload: Payload): boolean {
  if (payload.diagnosi_senza_errori === true) return true;
  if (typeof payload.esito_diagnosi === "string"
    && ["senza_errori", "senza_dtc", "nessun_errore"].includes(payload.esito_diagnosi.trim().toLowerCase())) return true;
  const testo = ["ultimo_messaggio_cliente", "messaggio_cliente", "messaggio", "descrizione_guasto", "riepilogo_operativo"]
    .map(k => typeof payload[k] === "string" ? payload[k] as string : "")
    .join("\n").toLowerCase();
  return /\b(?:nessun(?:o)?|non\s+(?:ci\s+sono|risultano|sono\s+presenti))\s+(?:errore|errori|dtc|codici?\s+(?:di\s+)?guasto)\b|\b(?:diagnosi|tester)\s+(?:senza\s+errori|non\s+rileva\s+(?:errori|guasti))\b|\bassenza\s+di\s+(?:errori|dtc|codici\s+guasto)\b/.test(testo);
}
