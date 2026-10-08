export function esitoRegistrazionePreventivo(result: unknown) {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    return { ok: false, status: 502, error: "Risposta della registrazione non valida" };
  }

  const esito = result as Record<string, unknown>;
  const registrato =
    (esito.aggiornato === true || esito.esito === "gia_registrato") &&
    typeof esito.preventivo_id === "string" &&
    typeof esito.pratica_id === "string" &&
    Boolean(esito.preventivo_id && esito.pratica_id);

  if (registrato) return { ok: true, status: 200 };

  if (esito.esito === "nome_file_non_valido" || esito.esito === "data_offerta_futura") {
    return { ok: false, status: 422, error: String(esito.esito) };
  }

  if (esito.aggiornato === false && typeof esito.esito === "string") {
    return { ok: false, status: 409, error: esito.esito };
  }

  return { ok: false, status: 502, error: "Esito della registrazione non verificabile" };
}
