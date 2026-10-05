type Dati = Record<string, unknown>;

function record(value: unknown): Dati {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Dati
    : {};
}

function stringa(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

/** Le installazioni Keplero che espongono solo ok/message devono ricevere
 * anche le decisioni, non soltanto una conferma tecnica del salvataggio. */
export function messaggioRaccoltaKeplero(
  contestoCliente: unknown,
  richiestaAmministrativa: unknown,
  statoImmagini: string,
) {
  const contesto = record(contestoCliente);
  const richiesta = record(richiestaAmministrativa);
  const indicazioni = ["Pratica sincronizzata con Dashboard Operatore."];

  if (contesto.stato === "riconosciuto" && contesto.cliente_riconosciuto === true) {
    const nome = stringa(contesto.denominazione);
    indicazioni.push(`Cliente già riconosciuto${nome ? `: ${JSON.stringify(nome)}` : ""}. Non chiedere nuovamente nome o ragione sociale.`);
    if (contesto.dati_fiscali_completi === true) {
      indicazioni.push("Dati fiscali già completi: non richiedere nuovamente anagrafica, partita IVA, codice fiscale, indirizzo o email. Chiedi solo eventuali variazioni o un diverso luogo di ritiro/spedizione quando necessario.");
    } else if (Array.isArray(contesto.campi_mancanti)) {
      const campi = contesto.campi_mancanti.map(stringa).filter(Boolean);
      if (campi.length) indicazioni.push(`Dopo una reale accettazione chiedi solo questi dati mancanti: ${campi.join(", ")}, escludendo quelli già acquisiti nella conversazione o nelle immagini.`);
    }
  } else if (["ambiguo", "da_verificare", "errore"].includes(stringa(contesto.stato))) {
    indicazioni.push("La consultazione dell’anagrafica richiede verifica dell’operatore. Non scegliere un cliente arbitrariamente e non ricominciare la richiesta di dati già ricevuti.");
  } else {
    const nome = stringa(contesto.nome_attivita_acquisito);
    if (nome) indicazioni.push(`Nome attività già acquisito: ${JSON.stringify(nome)}. Non richiederlo nuovamente.`);
    indicazioni.push("Conserva tutti i dati ricevuti nel testo e nelle immagini; chiedi solo quelli realmente mancanti.");
  }

  if (richiesta.necessaria === false && richiesta.stato === "completata") {
    indicazioni.push("Richiesta amministrativa completata: non inviare un nuovo elenco di dati fiscali.");
  } else if (richiesta.necessaria === true && contesto.dati_fiscali_completi !== true
    && !["ambiguo", "da_verificare", "errore"].includes(stringa(contesto.stato))) {
    const campi = Array.isArray(richiesta.campi) ? richiesta.campi.map(stringa).filter(Boolean) : [];
    if (campi.length) indicazioni.push(`Richiesta amministrativa: chiedi soltanto ${campi.join(", ")}, se non già forniti.`);
  }

  if (["file_non_trasmessi_da_keplero", "file_ricevuti_senza_codici"].includes(statoImmagini)) {
    indicazioni.push("Non chiedere di reinviare ripetutamente le stesse immagini. Un timbro o documento anagrafico non deve contenere codici del componente: acquisisci i suoi dati anagrafici. Per codici tecnici non leggibili inoltra la verifica all’operatore.");
  }
  return indicazioni.join(" ");
}
