type Dati = Record<string, unknown>;

function record(value: unknown): Dati {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Dati
    : {};
}

function stringa(value: unknown) {
  return typeof value === "string" ? value.trim() : "";
}

export function campiPerRichiestaFiscale(contestoCliente: unknown, campi: unknown): string[] {
  const contesto = record(contestoCliente);
  if (contesto.dati_fiscali_completi === true ||
      ["verifica_fatture_in_cloud", "ambiguo", "da_verificare", "errore"].includes(stringa(contesto.stato)) ||
      !Array.isArray(campi) || !campi.every((campo): campo is string => typeof campo === "string" && !!campo.trim())) {
    return [];
  }

  const mancanti = contesto.campi_mancanti;
  // Il sollecito contiene una frase già composta per tutti i campi richiesti.
  // Se anche uno è già acquisito, usiamo le indicazioni aggiornate della scheda.
  if (contesto.stato === "riconosciuto" && Array.isArray(mancanti) &&
      !campi.every(campo => mancanti.includes(campo))) return [];
  return campi;
}

export function indicazioniAnagraficheKeplero(contestoCliente: unknown, richiestaAmministrativa: unknown) {
  const contesto = record(contestoCliente);
  const richiesta = record(richiestaAmministrativa);
  const indicazioni: string[] = [];

  if (contesto.stato === "riconosciuto" && contesto.cliente_riconosciuto === true) {
    const nome = stringa(contesto.denominazione);
    indicazioni.push(`Cliente già riconosciuto${nome ? `: ${JSON.stringify(nome)}` : ""}. Non chiedere nuovamente nome o ragione sociale.`);
    if (contesto.dati_fiscali_completi === true) {
      indicazioni.push("Dati fiscali già completi: non richiedere nuovamente anagrafica, partita IVA, codice fiscale, indirizzo o email. Chiedi solo eventuali variazioni o un diverso luogo di ritiro/spedizione quando necessario.");
    } else if (Array.isArray(contesto.campi_mancanti)) {
      const campi = contesto.campi_mancanti.map(stringa).filter(Boolean);
      if (campi.length) indicazioni.push(`Dopo una reale accettazione chiedi solo questi dati mancanti: ${campi.join(", ")}, escludendo quelli già acquisiti nella conversazione o nelle immagini.`);
    }
  } else if (contesto.stato === "verifica_fatture_in_cloud") {
    indicazioni.push(stringa(contesto.istruzione) ||
      "Attendi la verifica interna in Fatture in Cloud. Non richiedere l’anagrafica al cliente.");
    indicazioni.push("Usa prima i dati già presenti nella pratica, in anagrafica o in chat. Chiedi al cliente solo un identificativo che la verifica indica espressamente come mancante.");
  } else if (["ambiguo", "da_verificare", "errore"].includes(stringa(contesto.stato))) {
    indicazioni.push("La consultazione dell’anagrafica richiede verifica dell’operatore. Non scegliere un cliente arbitrariamente e non ricominciare la richiesta di dati già ricevuti.");
  } else {
    const nome = stringa(contesto.nome_attivita_acquisito);
    if (nome) indicazioni.push(`Nome attività già acquisito: ${JSON.stringify(nome)}. Non richiederlo nuovamente.`);
    indicazioni.push("Conserva tutti i dati ricevuti nel testo e nelle immagini; chiedi solo quelli realmente mancanti.");
  }

  if (richiesta.necessaria === false && richiesta.stato === "completata") {
    indicazioni.push("Richiesta amministrativa completata: non inviare un nuovo elenco di dati fiscali.");
  } else if (richiesta.necessaria === true) {
    const campi = campiPerRichiestaFiscale(contesto, richiesta.campi);
    if (campi.length) indicazioni.push(`Richiesta amministrativa: chiedi soltanto ${campi.join(", ")}, se non già forniti.`);
  }

  return indicazioni.join(" ");
}

export function indicazioneIdentitaScambioNumerato(numero: number | null, scelta: unknown, contestoCliente: unknown): string {
  const s = record(scelta);
  const c = record(contestoCliente);
  if (numero === null || s.stato !== "confermata" || s.numero !== numero ||
      !["PS", "PSMI"].includes(stringa(s.servizio)) ||
      c.stato !== "verifica_fatture_in_cloud" || c.cliente_riconosciuto === true) return "";
  return " La scelta del Programma Scambio corrisponde all'alternativa numerata del preventivo. Per identificare l'officina e verificare i dati fiscali già presenti, chiedi soltanto la partita IVA, se non è già stata fornita. Non dichiarare che l'anagrafica è nuova o che la fattura è pronta prima del controllo.";
}

export function messaggioRaccoltaKeplero(
  contestoCliente: unknown,
  richiestaAmministrativa: unknown,
  statoImmagini: string,
) {
  const indicazioni = [
    "Pratica sincronizzata con Dashboard Operatore.",
    "Prima di chiedere dati rileggi quelli già acquisiti per la stessa vettura/dispositivo. DTC già ricevuti o esito esplicito di diagnosi senza errori chiudono la domanda sulle spie: non chiedere se/quali siano accese, conferma o foto del cruscotto. Spie dichiarate spente: non chiedere DTC solo per riconfermare il dato. Conserva i fatti reali, senza inventare spie o un esito diagnostico; eventuali contraddizioni esplicite richiedono verifica dell’operatore, senza domande ripetute.",
    indicazioniAnagraficheKeplero(contestoCliente, richiestaAmministrativa),
  ];
  if (["file_non_trasmessi_da_keplero", "file_ricevuti_senza_codici"].includes(statoImmagini)) {
    indicazioni.push("Non chiedere di reinviare ripetutamente le stesse immagini. Un timbro o documento anagrafico non deve contenere codici del componente: acquisisci i suoi dati anagrafici. Per codici tecnici non leggibili inoltra la verifica all’operatore.");
  }
  return indicazioni.join(" ");
}
