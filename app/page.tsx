import Link from "next/link";
import { randomUUID } from "node:crypto";
import {
  ApriPraticaConContesto,
  ContestoNavigazioneElenco,
} from "./components/NavigazionePratiche";
import {
  AccessoOperatore,
  BarraOperatore,
} from "./components/IdentitaOperatore";
import { getOperatoreAttivo } from "./operatore";
import {
  dataFatturaEffettiva,
  filtroMensileSolaLettura,
  haFatturaNelMese,
  haPreventivoNelMese,
  mesiDashboard,
} from "./lib/dashboardMensile";
import { fetchTutteLePagine } from "./lib/supabaseRest";

type Pratica = {
  id: string;
  codice_pratica: string;
  created_at: string;
  telefono: string | null;
  nome_cliente: string | null;
  targa: string | null;
  marca_veicolo: string | null;
  modello_veicolo: string | null;
  tipo_componente: string | null;
  stato_completezza: string;
  fonte_completezza?: string | null;
  stato_conferma_cliente?: "non_richiesta" | "in_attesa" | "confermato" | null;
  conferma_cliente_at?: string | null;
  da_preventivare_at?: string | null;
  da_verificare_at?: string | null;
  timer_preventivo_started_at?: string | null;
  minuti_attesa_lavorativi?: number | null;
  minuti_lavorativi_preventivo?: number | null;
  minuti_lavorativi_verifica?: number | null;
  stato_commerciale: string;
  stato_fatturazione: string;
  stato_followup: string;
  motivo_incompletezza: string | null;
  nota_incompletezza: string | null;
  blocco_operatore: boolean;
  preventivo_inviato_at: string | null;
  ordine_acquisito_at: string | null;
  followup_previsto_at: string | null;
  ultimo_importo_preventivo: number | null;
  numero_fattura: string | null;
  data_fattura: string | null;
  cliente_id?: string | null;
  stato_amministrativo?:
    | "non_applicabile"
    | "cliente_riconosciuto"
    | "dati_mancanti"
    | "corrispondenza_ambigua"
    | "pronto_fatturazione"
    | "completato"
    | null;
  stato_amministrativo_at?: string | null;
  nota_amministrativa?: string | null;
  stato_richiesta_amministrativa?:
    | "non_necessaria"
    | "da_inviare"
    | "inviata"
    | "completata"
    | "annullata"
    | null;
  campi_richiesta_amministrativa?: string[] | null;
  richiesta_amministrativa_preparata_at?: string | null;
  richiesta_amministrativa_inviata_at?: string | null;
  coda: string;
  priorita: number;
  tipo_flusso: string;
  stato_assistenza: string;
  tipo_assistenza: string | null;
  priorita_assistenza: string;
  nota_assistenza: string | null;
  fonte_classificazione: string;
  blocco_classificazione_operatore: boolean;
  assistenza_aperta_at: string | null;
  assistenza_chiusa_at: string | null;
  attivita_operative?: AttivitaOperatore[];
};

type AttivitaOperatore = {
  id: string;
  tipo:
    | "ritiro_programma_scambio"
    | "richiamata_post_preventivo"
    | "richiamata_post_vendita"
    | "richiamata_da_classificare";
  stato: "da_gestire" | "da_collegare" | "programmata";
  priorita: "normale" | "alta" | "urgente";
  pratica_id: string;
  pratica_origine_id: string | null;
  codice_pratica_origine: string | null;
  evidenza: string;
  richiesta_at: string;
};


type SegnalazioneK = {
  chiave: string; pratica_id: string | null; event_id: number;
  regola: string; descrizione: string; evidenza: string; rilevata_at: string;
};
type StatoControlloK = {
  ultima_esecuzione_at: string | null; eventi_esaminati: number;
  segnalazioni_aperte: number; risposte_k_disponibili: boolean; errore: string | null;
};

async function getControlloK(): Promise<{
  stato: StatoControlloK | null; segnalazioni: SegnalazioneK[]; errore: string | null;
}> {
  const url = process.env.SUPABASE_URL;
  const key = process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) return { stato: null, segnalazioni: [], errore: "Controllo non disponibile" };
  try {
    const headers = { apikey: key, Authorization: `Bearer ${key}` };
    const [stati, segnalazioni] = await Promise.all([
      fetchTutteLePagine<StatoControlloK>(`${url}/rest/v1/keplero_controllo_stato?select=*&order=id.asc`, { headers }),
      fetchTutteLePagine<SegnalazioneK>(`${url}/rest/v1/keplero_controllo_segnalazioni?select=*&risolta_at=is.null&order=rilevata_at.desc,chiave.asc`, { headers }),
    ]);
    return { stato: stati[0] || null, segnalazioni, errore: null };
  } catch (error) {
    console.error("Controllo coerenza K non disponibile:", error);
    return { stato: null, segnalazioni: [], errore: "Impossibile leggere l'esito del controllo" };
  }
}

function correggiCodaOperativa(pratica: Pratica): Pratica {
  // Le code assistenza sono già corrette nella view e restano intatte.
  if (pratica.tipo_flusso === "assistenza") {
    return pratica;
  }

  let coda = pratica.coda;
  let priorita = pratica.priorita;

  // Gli stati terminali prevalgono su qualunque dato storico di completezza.
  if (pratica.stato_commerciale === "rifiutato") {
    coda = "RIFIUTATA";
    priorita = 99;
  } else if (pratica.stato_commerciale === "chiuso") {
    coda = "CHIUSA";
    priorita = 99;
  } else if (pratica.stato_fatturazione === "fatturato") {
    // Una pratica fatturata non deve competere con attività ancora da svolgere.
    coda = "FATTURATA";
    priorita = 10;
  } else if (pratica.stato_fatturazione === "da_fatturare") {
    // La fatturazione prevale sul vecchio stato commerciale (es. preventivo_inviato).
    coda = "ORDINE ACQUISITO - DA FATTURARE";
    priorita = 3;
  } else if (pratica.stato_commerciale === "preventivo_inviato") {
    coda = "PREVENTIVO INVIATO";
    priorita = 9;
  } else if (pratica.stato_commerciale === "richiesta_verifica") {
    // L'operatore ha chiesto verifiche al cliente: la pratica resta in attesa
    // e NON deve competere con le vere pratiche "Da verificare".
    coda = "RICHIESTE VERIFICHE - ATTESA CLIENTE";
    priorita = 7;
  } else if (
    ["nuova", "raccolta_dati", "da_preventivare"].includes(
      pratica.stato_commerciale
    ) &&
    pratica.stato_completezza === "completa_da_preventivare"
  ) {
    // Solo una pratica commerciale ancora aperta può entrare nella coda preventivi.
    coda = "DA PREVENTIVARE";
    priorita = 2;
  } else if (pratica.stato_completezza === "dati_integrati_da_verificare") {
    coda = "DATI INTEGRATI - DA VERIFICARE";
    priorita = 6;
  } else if (pratica.stato_completezza === "dati_mancanti") {
    coda = "DATI MANCANTI";
    priorita = 8;
  }

  return {
    ...pratica,
    coda,
    priorita,
  };
}

function timestampOrdineCoda(pratica: Pratica) {
  if (pratica.coda === "DA PREVENTIVARE" && pratica.da_preventivare_at) {
    return new Date(pratica.da_preventivare_at).getTime();
  }

  if (
    pratica.coda === "DATI INTEGRATI - DA VERIFICARE" &&
    pratica.da_verificare_at
  ) {
    return new Date(pratica.da_verificare_at).getTime();
  }

  return new Date(pratica.created_at).getTime();
}

function ordinaCodaOperativa(pratiche: Pratica[]) {
  return [...pratiche].sort((a, b) => {
    if (a.priorita !== b.priorita) {
      return a.priorita - b.priorita;
    }

    return timestampOrdineCoda(a) - timestampOrdineCoda(b);
  });
}

async function getPratiche(): Promise<{
  pratiche: Pratica[];
  attivita: AttivitaOperatore[];
  errore: string | null;
}> {
  const url = process.env.SUPABASE_URL;
  const secretKey = process.env.SUPABASE_SECRET_KEY;

  if (!url || !secretKey) {
    return {
      pratiche: [],
      attivita: [],
      errore: "Variabili Supabase non configurate",
    };
  }

  try {
    const headers = {
      apikey: secretKey,
      Authorization: `Bearer ${secretKey}`,
    };

    const praticheBaseRaw = await fetchTutteLePagine<Pratica>(
      `${url}/rest/v1/v_coda_operatore_tempi?select=*&order=priorita.asc,created_at.asc,id.asc`,
      { headers }
    );

    // v_coda_operatore_tempi aggiunge il timer commerciale con i nomi
    // minuti_attesa_lavorativi e timer_preventivo_started_at.
    // Li normalizziamo sui campi già usati dalla dashboard, così tutti
    // i semafori esistenti continuano a funzionare senza duplicare logica.
    const praticheBase = praticheBaseRaw.map((pratica) => ({
      ...pratica,
      da_preventivare_at:
        pratica.da_preventivare_at ??
        pratica.timer_preventivo_started_at ??
        null,
      minuti_lavorativi_preventivo:
        pratica.minuti_attesa_lavorativi ??
        pratica.minuti_lavorativi_preventivo ??
        null,
    }));

    // I campi di conferma cliente sono letti direttamente da public.pratiche
    // e uniti per id. In questo modo la dashboard resta compatibile anche
    // con campi aggiunti dopo la creazione delle view operative.
    let metadati: Array<{
      id: string;
      fonte_completezza: string | null;
      stato_conferma_cliente:
        | "non_richiesta"
        | "in_attesa"
        | "confermato"
        | null;
      conferma_cliente_at: string | null;
      da_preventivare_at: string | null;
      da_verificare_at: string | null;
      cliente_id: string | null;
      stato_amministrativo: Pratica["stato_amministrativo"];
      stato_amministrativo_at: string | null;
      nota_amministrativa: string | null;
      stato_richiesta_amministrativa: Pratica["stato_richiesta_amministrativa"];
      campi_richiesta_amministrativa: string[] | null;
      richiesta_amministrativa_preparata_at: string | null;
      richiesta_amministrativa_inviata_at: string | null;
      data_fattura: string | null;
    }> = [];

    try {
      metadati = await fetchTutteLePagine(
        `${url}/rest/v1/pratiche?select=id,fonte_completezza,stato_conferma_cliente,conferma_cliente_at,da_preventivare_at,da_verificare_at,cliente_id,stato_amministrativo,stato_amministrativo_at,nota_amministrativa,stato_richiesta_amministrativa,campi_richiesta_amministrativa,richiesta_amministrativa_preparata_at,richiesta_amministrativa_inviata_at,data_fattura&order=id.asc`,
        { headers }
      );
    } catch (error) {
      // La dashboard deve continuare a funzionare anche se i soli
      // metadati aggiuntivi non fossero temporaneamente leggibili.
      console.error("Metadati pratiche non disponibili:", error);
    }

    const metadatiPerId = new Map(
      metadati.map((riga) => [riga.id, riga])
    );

    // I semafori devono usare minuti LAVORATIVI, non tempo di calendario.
    // Il timer preventivo arriva già da v_coda_operatore_tempi.
    // Manteniamo v_tempi_operativi_dashboard per il timer "Da verificare"
    // e come fallback compatibile per il preventivo.
    let tempiPerId = new Map<
      string,
      {
        id: string;
        minuti_lavorativi_preventivo: number | null;
        minuti_lavorativi_verifica: number | null;
      }
    >();

    try {
      const tempi = await fetchTutteLePagine<{
        id: string;
        minuti_lavorativi_preventivo: number | null;
        minuti_lavorativi_verifica: number | null;
      }>(
        `${url}/rest/v1/v_tempi_operativi_dashboard?select=id,minuti_lavorativi_preventivo,minuti_lavorativi_verifica&order=id.asc`,
        { headers }
      );

      tempiPerId = new Map(tempi.map((riga) => [riga.id, riga]));
    } catch (error) {
      console.error("Tempi lavorativi dashboard non disponibili:", error);
    }

    const praticheComplete = praticheBase.map((pratica) => {
      const meta = metadatiPerId.get(pratica.id);
      const tempi = tempiPerId.get(pratica.id);

      return {
        ...pratica,
        ...(meta
          ? {
              fonte_completezza: meta.fonte_completezza,
              stato_conferma_cliente: meta.stato_conferma_cliente,
              conferma_cliente_at: meta.conferma_cliente_at,
              da_preventivare_at: meta.da_preventivare_at,
              da_verificare_at: meta.da_verificare_at,
              cliente_id: meta.cliente_id,
              stato_amministrativo: meta.stato_amministrativo,
              stato_amministrativo_at: meta.stato_amministrativo_at,
              nota_amministrativa: meta.nota_amministrativa,
              stato_richiesta_amministrativa:
                meta.stato_richiesta_amministrativa,
              campi_richiesta_amministrativa:
                meta.campi_richiesta_amministrativa,
              richiesta_amministrativa_preparata_at:
                meta.richiesta_amministrativa_preparata_at,
              richiesta_amministrativa_inviata_at:
                meta.richiesta_amministrativa_inviata_at,
              data_fattura: meta.data_fattura,
            }
          : {}),
        minuti_lavorativi_preventivo:
          pratica.minuti_lavorativi_preventivo ??
          tempi?.minuti_lavorativi_preventivo ??
          null,
        minuti_lavorativi_verifica:
          tempi?.minuti_lavorativi_verifica ??
          pratica.minuti_lavorativi_verifica ??
          null,
      };
    });

    const praticheCorrette = ordinaCodaOperativa(
      praticheComplete.map(correggiCodaOperativa)
    );

    let attivita: AttivitaOperatore[] = [];
    try {
      attivita = await fetchTutteLePagine<AttivitaOperatore>(
        `${url}/rest/v1/v_attivita_operatore_aperte?select=id,tipo,stato,priorita,pratica_id,pratica_origine_id,codice_pratica_origine,evidenza,richiesta_at&order=priorita.desc,richiesta_at.asc,id.asc`,
        { headers }
      );
    } catch (error) {
      console.error("Coda attività operative non disponibile:", error);
    }

    const attivitaPerPratica = new Map<string, AttivitaOperatore[]>();
    for (const voce of attivita) {
      const elenco = attivitaPerPratica.get(voce.pratica_id) || [];
      elenco.push(voce);
      attivitaPerPratica.set(voce.pratica_id, elenco);
    }

    return {
      pratiche: praticheCorrette.map((pratica) => ({
        ...pratica,
        attivita_operative: attivitaPerPratica.get(pratica.id) || [],
      })),
      attivita,
      errore: null,
    };
  } catch (error) {
    return {
      pratiche: [],
      attivita: [],
      errore:
        error instanceof Error
          ? error.message
          : "Errore sconosciuto durante la connessione",
    };
  }
}

function conta(pratiche: Pratica[], coda: string) {
  return pratiche.filter((pratica) => pratica.coda === coda).length;
}

function contaAmministrazione(pratiche: Pratica[], stato: string) {
  return pratiche.filter(
    (pratica) =>
      pratica.stato_fatturazione === "da_fatturare" &&
      pratica.stato_amministrativo === stato
  ).length;
}

function contaRichiesteAmministrative(pratiche: Pratica[], stato: string) {
  return pratiche.filter(
    (pratica) => pratica.stato_richiesta_amministrativa === stato
  ).length;
}

function contaAssistenzaDaEvadere(pratiche: Pratica[]) {
  return pratiche.filter(
    (pratica) =>
      pratica.tipo_flusso === "assistenza" &&
      ["nuova", "da_verificare"].includes(pratica.stato_assistenza)
  ).length;
}

function contaAssistenzaAperta(pratiche: Pratica[]) {
  return pratiche.filter(
    (pratica) =>
      pratica.tipo_flusso === "assistenza" &&
      ["in_gestione", "attesa_cliente", "attesa_rientro"].includes(
        pratica.stato_assistenza
      )
  ).length;
}

function contaAssistenzaPrioritaria(pratiche: Pratica[]) {
  return pratiche.filter(
    (pratica) =>
      pratica.tipo_flusso === "assistenza" &&
      pratica.priorita_assistenza === "urgente" &&
      !["risolta", "chiusa"].includes(pratica.stato_assistenza)
  ).length;
}

function haAttivita(pratica: Pratica, ...tipi: AttivitaOperatore["tipo"][]) {
  return (pratica.attivita_operative || []).some((attivita) =>
    tipi.includes(attivita.tipo)
  );
}

function etichettaAttivita(tipo: AttivitaOperatore["tipo"]) {
  switch (tipo) {
    case "ritiro_programma_scambio":
      return "Ritiro da organizzare";
    case "richiamata_post_preventivo":
      return "Richiamata post-preventivo";
    case "richiamata_post_vendita":
      return "Richiamata post-vendita";
    default:
      return "Richiamata da classificare";
  }
}

function formattaData(data: string | null) {
  if (!data) return "—";
  return new Intl.DateTimeFormat("it-IT", {
    dateStyle: "short",
    timeStyle: "short",
    timeZone: "Europe/Rome",
  }).format(new Date(data));
}

function formattaImporto(importo: number | null) {
  if (importo === null || importo === undefined) return "—";
  return new Intl.NumberFormat("it-IT", {
    style: "currency",
    currency: "EUR",
  }).format(importo);
}

function attesaDaPreventivare(pratica: Pratica) {
  if (
    pratica.coda !== "DA PREVENTIVARE" ||
    pratica.minuti_lavorativi_preventivo === null ||
    pratica.minuti_lavorativi_preventivo === undefined ||
    !Number.isFinite(pratica.minuti_lavorativi_preventivo)
  ) {
    return null;
  }

  const minuti = Math.max(0, Math.floor(pratica.minuti_lavorativi_preventivo));
  const ore = Math.floor(minuti / 60);
  const minutiResidui = minuti % 60;

  const durata =
    ore > 0
      ? `${ore}h ${String(minutiResidui).padStart(2, "0")}m`
      : `${minuti} min`;

  if (minuti >= 60) {
    return {
      minuti,
      durata,
      livello: "urgente" as const,
      label: `URGENTE · ${durata} lavorativi`,
      badgeClass: "bg-red-100 text-red-800 ring-1 ring-red-200",
      rowClass: "bg-red-50/70 hover:bg-red-100",
    };
  }

  if (minuti >= 30) {
    return {
      minuti,
      durata,
      livello: "attenzione" as const,
      label: `ATTENZIONE · ${durata} lavorativi`,
      badgeClass: "bg-amber-100 text-amber-900 ring-1 ring-amber-200",
      rowClass: "bg-amber-50/60 hover:bg-amber-100",
    };
  }

  return {
    minuti,
    durata,
    livello: "normale" as const,
    label: `${durata} lavorativi`,
    badgeClass: "bg-green-100 text-green-800 ring-1 ring-green-200",
    rowClass: "hover:bg-slate-50",
  };
}

function attesaDaVerificare(pratica: Pratica) {
  if (
    pratica.coda !== "DATI INTEGRATI - DA VERIFICARE" ||
    pratica.minuti_lavorativi_verifica === null ||
    pratica.minuti_lavorativi_verifica === undefined ||
    !Number.isFinite(pratica.minuti_lavorativi_verifica)
  ) {
    return null;
  }

  const minuti = Math.max(0, Math.floor(pratica.minuti_lavorativi_verifica));
  const oreTotali = Math.floor(minuti / 60);
  const minutiResidui = minuti % 60;

  const durata =
    oreTotali > 0
      ? `${oreTotali}h ${String(minutiResidui).padStart(2, "0")}m`
      : `${minuti} min`;

  if (minuti >= 24 * 60) {
    return {
      minuti,
      durata,
      livello: "urgente" as const,
      label: `URGENTE · ${durata} lavorative`,
      badgeClass: "bg-red-100 text-red-800 ring-1 ring-red-200",
      rowClass: "bg-red-50/70 hover:bg-red-100",
    };
  }

  if (minuti >= 4 * 60) {
    return {
      minuti,
      durata,
      livello: "attenzione" as const,
      label: `ATTENZIONE · ${durata} lavorative`,
      badgeClass: "bg-amber-100 text-amber-900 ring-1 ring-amber-200",
      rowClass: "bg-amber-50/60 hover:bg-amber-100",
    };
  }

  return {
    minuti,
    durata,
    livello: "normale" as const,
    label: `${durata} lavorative`,
    badgeClass: "bg-green-100 text-green-800 ring-1 ring-green-200",
    rowClass: "hover:bg-slate-50",
  };
}

function statoConfermaClienteVisuale(
  pratica: Pratica
): "non_richiesta" | "confermato" {
  // FIX_CONFERMA_RIEPILOGO_UI_20260911: modifica soltanto la presentazione.
  // Il nuovo flusso non richiede la conferma del riepilogo per procedere.
  // Un vecchio "in_attesa" o la completezza AI non generano piu un avviso.
  // I valori registrati nel database e le azioni operatore restano invariati.
  // Manteniamo le conferme gia registrate nelle stesse fasi di prima.
  const faseInizialeCommerciale =
    pratica.tipo_flusso === "commerciale" &&
    ["raccolta_dati", "richiesta_verifica", "da_preventivare"].includes(
      pratica.stato_commerciale ?? ""
    );

  if (
    faseInizialeCommerciale &&
    pratica.stato_conferma_cliente === "confermato"
  ) {
    return "confermato";
  }

  return "non_richiesta";
}

function testoTipoAssistenza(tipo: string | null) {
  switch (tipo) {
    case "post_riparazione":
      return "Post-riparazione";
    case "post_scambio":
      return "Post-scambio";
    case "garanzia":
      return "Garanzia";
    case "montaggio_codifica":
      return "Montaggio / codifica";
    case "diagnostica":
      return "Diagnostica";
    case "spedizione_rientro":
      return "Spedizione / rientro";
    case "amministrativa":
      return "Amministrativa";
    case "altro":
      return "Altro";
    default:
      return "—";
  }
}

function testoStatoAssistenza(stato: string) {
  switch (stato) {
    case "nuova":
      return "Nuova";
    case "da_verificare":
      return "Da verificare";
    case "in_gestione":
      return "In gestione";
    case "attesa_cliente":
      return "Attesa cliente";
    case "attesa_rientro":
      return "Attesa rientro";
    case "risolta":
      return "Risolta";
    case "chiusa":
      return "Chiusa";
    default:
      return "—";
  }
}

function badgeClass(coda: string) {
  switch (coda) {
    case "ASSISTENZA PRIORITARIA":
      return "bg-red-100 text-red-800";
    case "ASSISTENZA - DA VERIFICARE":
      return "bg-fuchsia-100 text-fuchsia-800";
    case "ASSISTENZA APERTA":
      return "bg-purple-100 text-purple-800";
    case "ASSISTENZA CHIUSA":
      return "bg-slate-100 text-slate-600";
    case "ORDINE ACQUISITO - DA FATTURARE":
      return "bg-red-100 text-red-800";
    case "DA PREVENTIVARE":
      return "bg-orange-100 text-orange-800";
    case "DATI INTEGRATI - DA VERIFICARE":
      return "bg-yellow-100 text-yellow-800";
    case "RICHIESTE VERIFICHE - ATTESA CLIENTE":
      return "bg-cyan-100 text-cyan-800";
    case "INCOMPLETA - OPERATORE":
      return "bg-rose-100 text-rose-800";
    case "DATI MANCANTI":
      return "bg-slate-200 text-slate-800";
    case "PREVENTIVO INVIATO":
      return "bg-blue-100 text-blue-800";
    case "FATTURATA":
      return "bg-green-100 text-green-800";
    default:
      return "bg-gray-100 text-gray-800";
  }
}

function prioritaClass(pratica: Pratica) {
  if (
    pratica.tipo_flusso === "assistenza" &&
    pratica.priorita_assistenza === "urgente"
  ) {
    return "bg-red-100 text-red-800";
  }

  if (
    pratica.tipo_flusso === "assistenza" &&
    pratica.priorita_assistenza === "alta"
  ) {
    return "bg-orange-100 text-orange-800";
  }

  return "bg-slate-100 text-slate-700";
}


function filtraPratiche(
  pratiche: Pratica[],
  filtro: string,
  meseCorrente: string,
  mesePrecedente: string
) {
  switch (filtro) {
    case "assistenza_da_evadere":
      return pratiche.filter(
        (pratica) =>
          pratica.tipo_flusso === "assistenza" &&
          ["nuova", "da_verificare"].includes(pratica.stato_assistenza)
      );

    case "assistenza_aperta":
      return pratiche.filter(
        (pratica) =>
          pratica.tipo_flusso === "assistenza" &&
          ["in_gestione", "attesa_cliente", "attesa_rientro"].includes(
            pratica.stato_assistenza
          )
      );

    case "assistenza_prioritaria":
      return pratiche.filter(
        (pratica) =>
          pratica.tipo_flusso === "assistenza" &&
          pratica.priorita_assistenza === "urgente" &&
          !["risolta", "chiusa"].includes(pratica.stato_assistenza)
      );

    case "ritiri_programma_scambio":
      return pratiche.filter((pratica) =>
        haAttivita(pratica, "ritiro_programma_scambio")
      );

    case "richiamate_post_preventivo":
      return pratiche.filter((pratica) =>
        haAttivita(pratica, "richiamata_post_preventivo")
      );

    case "richiamate_post_vendita":
      return pratiche.filter((pratica) =>
        haAttivita(pratica, "richiamata_post_vendita")
      );

    case "richiamate_da_classificare":
      return pratiche.filter((pratica) =>
        haAttivita(pratica, "richiamata_da_classificare")
      );

    case "dati_mancanti":
      return pratiche.filter((pratica) => pratica.coda === "DATI MANCANTI");

    case "da_verificare":
      return pratiche.filter(
        (pratica) => pratica.coda === "DATI INTEGRATI - DA VERIFICARE"
      );

    case "richieste_verifiche":
      return pratiche.filter(
        (pratica) =>
          pratica.coda === "RICHIESTE VERIFICHE - ATTESA CLIENTE"
      );

    case "da_preventivare":
      return pratiche.filter((pratica) => pratica.coda === "DA PREVENTIVARE");

    case "preventivi_in_attesa":
      return pratiche.filter((pratica) => pratica.coda === "PREVENTIVO INVIATO");

    case "preventivi_inviati":
    case "preventivi_mese_corrente":
      return pratiche.filter((pratica) =>
        haPreventivoNelMese(pratica, meseCorrente)
      );

    case "preventivi_mese_precedente":
      return pratiche.filter((pratica) =>
        haPreventivoNelMese(pratica, mesePrecedente)
      );

    case "da_fatturare":
      return pratiche.filter(
        (pratica) => pratica.coda === "ORDINE ACQUISITO - DA FATTURARE"
      );

    case "fatturate":
    case "fatture_mese_corrente":
      return pratiche.filter((pratica) =>
        haFatturaNelMese(pratica, meseCorrente)
      );

    case "fatture_mese_precedente":
      return pratiche.filter((pratica) =>
        haFatturaNelMese(pratica, mesePrecedente)
      );

    case "admin_cliente_riconosciuto":
      return pratiche.filter(
        (pratica) =>
          pratica.stato_fatturazione === "da_fatturare" &&
          pratica.stato_amministrativo === "cliente_riconosciuto"
      );

    case "admin_dati_mancanti":
      return pratiche.filter(
        (pratica) =>
          pratica.stato_fatturazione === "da_fatturare" &&
          pratica.stato_amministrativo === "dati_mancanti"
      );

    case "admin_corrispondenza_ambigua":
      return pratiche.filter(
        (pratica) =>
          pratica.stato_fatturazione === "da_fatturare" &&
          pratica.stato_amministrativo === "corrispondenza_ambigua"
      );

    case "admin_pronto_fatturazione":
      return pratiche.filter(
        (pratica) =>
          pratica.stato_fatturazione === "da_fatturare" &&
          pratica.stato_amministrativo === "pronto_fatturazione"
      );

    case "admin_richieste_da_inviare":
      return pratiche.filter(
        (pratica) => pratica.stato_richiesta_amministrativa === "da_inviare"
      );

    case "admin_attesa_dati_cliente":
      return pratiche.filter(
        (pratica) => pratica.stato_richiesta_amministrativa === "inviata"
      );

    default:
      return pratiche;
  }
}

function labelFiltro(
  filtro: string,
  etichettaCorrente = "mese corrente",
  etichettaPrecedente = "mese precedente"
) {
  switch (filtro) {
    case "assistenza_da_evadere":
      return "Assistenze da evadere";
    case "assistenza_aperta":
      return "Assistenza aperta";
    case "assistenza_prioritaria":
      return "Assistenza prioritaria";
    case "ritiri_programma_scambio":
      return "Ritiri programma scambio";
    case "richiamate_post_preventivo":
      return "Richiamate post-preventivo";
    case "richiamate_post_vendita":
      return "Richiamate post-vendita";
    case "richiamate_da_classificare":
      return "Richiamate da classificare";
    case "dati_mancanti":
      return "Dati mancanti";
    case "da_verificare":
      return "Da verificare";
    case "richieste_verifiche":
      return "Richieste verifiche / Attesa cliente";
    case "da_preventivare":
      return "Da preventivare";
    case "preventivi_inviati":
    case "preventivi_mese_corrente":
      return `Preventivi emessi · ${etichettaCorrente}`;
    case "preventivi_in_attesa":
      return "Preventivi in attesa";
    case "preventivi_mese_precedente":
      return `Preventivi mese precedente · ${etichettaPrecedente}`;
    case "da_fatturare":
      return "Da fatturare";
    case "fatturate":
    case "fatture_mese_corrente":
      return `Fatture emesse · ${etichettaCorrente}`;
    case "fatture_mese_precedente":
      return `Fatture mese precedente · ${etichettaPrecedente}`;
    case "admin_cliente_riconosciuto":
      return "Cliente riconosciuto";
    case "admin_dati_mancanti":
      return "Dati amministrativi mancanti";
    case "admin_corrispondenza_ambigua":
      return "Corrispondenza ambigua";
    case "admin_pronto_fatturazione":
      return "Dati completi / pronto per fatturazione";
    case "admin_richieste_da_inviare":
      return "Richieste dati da inviare";
    case "admin_attesa_dati_cliente":
      return "In attesa dei dati cliente";
    default:
      return "Tutte le pratiche";
  }
}

export default async function Home({
  searchParams,
}: {
  searchParams: Promise<{
    filtro?: string | string[];
    cerca?: string | string[];
  }>;
}) {
  const operatoreAttivo = await getOperatoreAttivo();

  if (!operatoreAttivo) {
    return <AccessoOperatore />;
  }

  const [{ pratiche, attivita, errore }, controlloK] = await Promise.all([
    getPratiche(), getControlloK(),
  ]);
  const controlloKInRitardo = !controlloK.stato?.ultima_esecuzione_at ||
    Date.now() - new Date(controlloK.stato.ultima_esecuzione_at).getTime() > 15 * 60_000;
  const params = await searchParams;

  const filtroAttivo = Array.isArray(params?.filtro)
    ? params.filtro[0]
    : params?.filtro || "tutte";

  const cercaAttiva = (
    Array.isArray(params?.cerca)
      ? params.cerca[0]
      : params?.cerca || ""
  ).trim();

  const mesi = mesiDashboard();
  const solaLettura = filtroMensileSolaLettura(filtroAttivo);

  const praticheFiltratePerStato = filtraPratiche(
    pratiche,
    filtroAttivo,
    mesi.corrente,
    mesi.precedente
  );
  const termineRicerca = cercaAttiva.toLowerCase();

  const praticheFiltrate = termineRicerca
    ? praticheFiltratePerStato.filter((pratica) =>
        Object.values(pratica).some((valore) =>
          String(valore ?? "").toLowerCase().includes(termineRicerca)
        )
      )
    : praticheFiltratePerStato;

  // NAVIGAZIONE_PRATICHE_V1_20260911: sequenza esatta DOPO filtro e ricerca.
  // Il componente riceve id/codice e filtro/ricerca, non payload o credenziali.
  const chiaveNavigazione = randomUUID();
  const vociNavigazione = solaLettura
    ? []
    : praticheFiltrate.map((pratica) => ({
        id: pratica.id,
        codice: pratica.codice_pratica,
      }));

  const hrefConFiltro = (filtro: string) => {
    const query = new URLSearchParams();

    if (filtro !== "tutte") {
      query.set("filtro", filtro);
    }

    if (cercaAttiva) {
      query.set("cerca", cercaAttiva);
    }

    const stringaQuery = query.toString();
    return stringaQuery ? `/?${stringaQuery}` : "/";
  };

  const hrefAzzeraRicerca =
    filtroAttivo === "tutte"
      ? "/"
      : `/?filtro=${encodeURIComponent(filtroAttivo)}`;

  const assistenzaDaEvadere = contaAssistenzaDaEvadere(pratiche);
  const assistenzaAperta = contaAssistenzaAperta(pratiche);
  const assistenzaPrioritaria = contaAssistenzaPrioritaria(pratiche);
  const ritiriProgrammaScambio = attivita.filter(
    (voce) => voce.tipo === "ritiro_programma_scambio"
  ).length;
  const richiamatePostPreventivo = attivita.filter(
    (voce) => voce.tipo === "richiamata_post_preventivo"
  ).length;
  const richiamatePostVendita = attivita.filter(
    (voce) => voce.tipo === "richiamata_post_vendita"
  ).length;
  const richiamateDaClassificare = attivita.filter(
    (voce) => voce.tipo === "richiamata_da_classificare"
  ).length;

  const datiMancanti = conta(pratiche, "DATI MANCANTI");
  const daVerificare = conta(pratiche, "DATI INTEGRATI - DA VERIFICARE");
  const richiesteVerifiche = conta(
    pratiche,
    "RICHIESTE VERIFICHE - ATTESA CLIENTE"
  );
  const verificheUrgenti = pratiche.filter((pratica) => {
    const attesa = attesaDaVerificare(pratica);
    return attesa?.livello === "urgente";
  }).length;
  const verificheAttenzione = pratiche.filter((pratica) => {
    const attesa = attesaDaVerificare(pratica);
    return attesa?.livello === "attenzione";
  }).length;
  const daPreventivare = conta(pratiche, "DA PREVENTIVARE");
  const preventiviUrgenti = pratiche.filter((pratica) => {
    const attesa = attesaDaPreventivare(pratica);
    return attesa?.livello === "urgente";
  }).length;
  const preventiviMeseCorrente = pratiche.filter((pratica) =>
    haPreventivoNelMese(pratica, mesi.corrente)
  ).length;
  const preventiviInAttesa = conta(pratiche, "PREVENTIVO INVIATO");
  const preventiviMesePrecedente = pratiche.filter((pratica) =>
    haPreventivoNelMese(pratica, mesi.precedente)
  ).length;
  const daFatturare = conta(pratiche, "ORDINE ACQUISITO - DA FATTURARE");
  const fattureMeseCorrente = pratiche.filter((pratica) =>
    haFatturaNelMese(pratica, mesi.corrente)
  ).length;
  const fattureMesePrecedente = pratiche.filter((pratica) =>
    haFatturaNelMese(pratica, mesi.precedente)
  ).length;
  const clientiRiconosciuti = contaAmministrazione(
    pratiche,
    "cliente_riconosciuto"
  );
  const datiAmministrativiMancanti = contaAmministrazione(
    pratiche,
    "dati_mancanti"
  );
  const corrispondenzeAmbigue = contaAmministrazione(
    pratiche,
    "corrispondenza_ambigua"
  );
  const prontiFatturazione = contaAmministrazione(
    pratiche,
    "pronto_fatturazione"
  );
  const richiesteAmministrativeDaInviare = contaRichiesteAmministrative(
    pratiche,
    "da_inviare"
  );
  const richiesteAmministrativeInviate = contaRichiesteAmministrative(
    pratiche,
    "inviata"
  );

  return (
    <ContestoNavigazioneElenco
      chiave={chiaveNavigazione}
      filtro={filtroAttivo}
      etichetta={labelFiltro(
        filtroAttivo,
        mesi.etichettaCorrente,
        mesi.etichettaPrecedente
      )}
      cerca={cercaAttiva}
      voci={vociNavigazione}
    >
    <main className="min-h-screen bg-slate-50">
      <BarraOperatore operatore={operatoreAttivo} />

      <div className="mx-auto max-w-[1750px] px-6 py-8">
        <header className="mb-8 flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
          <div>
            <p className="mb-1 text-sm font-semibold uppercase tracking-[0.18em] text-slate-500">
              Italiana Ricambi / ItalianaABS
            </p>
            <h1 className="text-3xl font-bold tracking-tight text-slate-950">
              Dashboard Operatore
            </h1>
            <p className="mt-2 text-sm text-slate-600">
              Preventivi, assistenza, ordini acquisiti e controllo fatturazione
            </p>
          </div>

          <div
            className={`rounded-full px-4 py-2 text-sm font-semibold ${
              errore
                ? "bg-red-100 text-red-800"
                : "bg-green-100 text-green-800"
            }`}
          >
            {errore
              ? "Connessione database da verificare"
              : "Supabase collegato"}
          </div>
        </header>

        {errore && (
          <div className="mb-6 rounded-2xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">
            <strong>Errore di collegamento:</strong> {errore}
          </div>
        )}

        <section className="mb-6 rounded-2xl border border-amber-200 bg-white p-5">
          <h2 className="text-lg font-bold text-slate-950">Controllo coerenza K e Dashboard</h2>
          <p className="mt-1 text-sm text-slate-600">
            Messaggi ricevuti nelle ultime 48 ore confrontati con preventivi e stati della pratica.
            Le incongruenze richiedono una verifica dell’operatore.
          </p>
          {controlloK.errore || controlloK.stato?.errore || controlloKInRitardo ? (
            <p className="mt-3 font-semibold text-red-700">
              {controlloK.errore || controlloK.stato?.errore || "Controllo non aggiornato: ultima esecuzione assente o oltre 15 minuti fa"}
            </p>
          ) : (
            <p className="mt-3 text-sm text-slate-700">
              Ultimo controllo: {formattaData(controlloK.stato?.ultima_esecuzione_at || null)} · {controlloK.stato?.eventi_esaminati} eventi esaminati · {controlloK.segnalazioni.length} segnalazioni aperte
            </p>
          )}
          <p className="mt-2 text-sm text-amber-800">
            Copertura parziale: le risposte di K non sono trasmesse alla dashboard.
            Le istruzioni su privati e imballaggio richiedono ancora il controllo della conversazione originale.
            I messaggi che K non trasmette non possono essere verificati qui.
          </p>
          <details className="mt-3" open={controlloK.segnalazioni.length > 0}>
            <summary className="cursor-pointer text-sm font-semibold text-slate-800">Segnalazioni da verificare ({controlloK.segnalazioni.length})</summary>
            <div className="mt-3 max-h-96 space-y-3 overflow-y-auto">
              {controlloK.segnalazioni.map((voce) => {
                const pratica = pratiche.find((p) => p.id === voce.pratica_id);
                return (
                  <div key={voce.chiave} className="rounded-lg border border-amber-100 bg-amber-50 p-3 text-sm">
                    <p className="font-semibold text-slate-900">
                      {voce.pratica_id ? <Link className="underline" href={`/pratica/${voce.pratica_id}`}>{pratica?.codice_pratica || "Apri pratica"}{pratica?.targa ? ` · ${pratica.targa}` : ""}</Link> : "Evento senza pratica"} · Evento {voce.event_id}
                    </p>
                    <p className="mt-1 text-slate-700">{voce.descrizione}</p>
                    {voce.evidenza && <p className="mt-1 whitespace-pre-wrap text-slate-600">Messaggio: {voce.evidenza}</p>}
                  </div>
                );
              })}
              {controlloK.segnalazioni.length === 0 && !controlloKInRitardo && !controlloK.errore && !controlloK.stato?.errore && <p className="text-sm text-slate-600">Nessuna incoerenza rilevata dalle regole attive.</p>}
            </div>
          </details>
        </section>

        <section className="mb-5">
          <h2 className="mb-3 text-sm font-bold uppercase tracking-wider text-slate-500">
            Attività operative
          </h2>

          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <DashboardFilterCard
              titolo="Ritiri programma scambio"
              valore={ritiriProgrammaScambio}
              descrizione="Prodotti da ritirare, programmare o collegare all’ordine"
              className="border-amber-500"
              href={hrefConFiltro("ritiri_programma_scambio")}
              attiva={filtroAttivo === "ritiri_programma_scambio"}
            />
            <DashboardFilterCard
              titolo="Richiamate post-preventivo"
              valore={richiamatePostPreventivo}
              descrizione="Delucidazioni richieste su offerte già inviate"
              className="border-sky-500"
              href={hrefConFiltro("richiamate_post_preventivo")}
              attiva={filtroAttivo === "richiamate_post_preventivo"}
            />
            <DashboardFilterCard
              titolo="Richiamate post-vendita"
              valore={richiamatePostVendita}
              descrizione="Clienti con ordine, fattura o assistenza in corso"
              className="border-violet-500"
              href={hrefConFiltro("richiamate_post_vendita")}
              attiva={filtroAttivo === "richiamate_post_vendita"}
            />
            <DashboardFilterCard
              titolo="Richiamate da classificare"
              valore={richiamateDaClassificare}
              descrizione="Richiesta chiara, ma contesto commerciale non univoco"
              className="border-slate-400"
              href={hrefConFiltro("richiamate_da_classificare")}
              attiva={filtroAttivo === "richiamate_da_classificare"}
            />
          </div>
        </section>

        <section className="mb-5">
          <h2 className="mb-3 text-sm font-bold uppercase tracking-wider text-slate-500">
            Assistenza / Post-vendita
          </h2>

          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            <DashboardFilterCard
              titolo="Assistenze da evadere"
              valore={assistenzaDaEvadere}
              descrizione="Nuove richieste non ancora prese in carico"
              className="border-violet-500"
              href={hrefConFiltro("assistenza_da_evadere")}
              attiva={filtroAttivo === "assistenza_da_evadere"}
            />
            <DashboardFilterCard
              titolo="Assistenza aperta"
              valore={assistenzaAperta}
              descrizione="Pratiche già in gestione o in attesa"
              className="border-purple-400"
              href={hrefConFiltro("assistenza_aperta")}
              attiva={filtroAttivo === "assistenza_aperta"}
            />
            <DashboardFilterCard
              titolo="Assistenza prioritaria"
              valore={assistenzaPrioritaria}
              descrizione="Richieste urgenti che richiedono intervento immediato"
              className="border-red-500"
              href={hrefConFiltro("assistenza_prioritaria")}
              attiva={filtroAttivo === "assistenza_prioritaria"}
            />
          </div>
        </section>

        <section>
          <h2 className="mb-3 text-sm font-bold uppercase tracking-wider text-slate-500">
            Commerciale
          </h2>

          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
            <DashboardFilterCard
              titolo="Dati mancanti"
              valore={datiMancanti}
              descrizione="Pratiche ancora incomplete"
              className="border-slate-300"
              href={hrefConFiltro("dati_mancanti")}
              attiva={filtroAttivo === "dati_mancanti"}
            />
            <DashboardFilterCard
              titolo="Da verificare"
              valore={daVerificare}
              descrizione={
                verificheUrgenti > 0
                  ? `${verificheUrgenti} ${
                      verificheUrgenti === 1
                        ? "pratica oltre 24 ore lavorative"
                        : "pratiche oltre 24 ore lavorative"
                    }`
                  : verificheAttenzione > 0
                  ? `${verificheAttenzione} ${
                      verificheAttenzione === 1
                        ? "pratica oltre 4 ore lavorative"
                        : "pratiche oltre 4 ore lavorative"
                    }`
                  : "Nuovi dati dopo intervento operatore"
              }
              className={
                verificheUrgenti > 0
                  ? "border-red-500"
                  : verificheAttenzione > 0
                  ? "border-amber-400"
                  : "border-yellow-300"
              }
              href={hrefConFiltro("da_verificare")}
              attiva={filtroAttivo === "da_verificare"}
            />
            <DashboardFilterCard
              titolo="Richieste verifiche"
              valore={richiesteVerifiche}
              descrizione="Verifiche richieste al cliente, in attesa di risposta"
              className="border-cyan-400"
              href={hrefConFiltro("richieste_verifiche")}
              attiva={filtroAttivo === "richieste_verifiche"}
            />
            <DashboardFilterCard
              titolo="Da preventivare"
              valore={daPreventivare}
              descrizione={
                preventiviUrgenti > 0
                  ? `${preventiviUrgenti} ${
                      preventiviUrgenti === 1
                        ? "pratica oltre 60 min lavorativi"
                        : "pratiche oltre 60 min lavorativi"
                    }`
                  : "Dati completi, offerta da preparare"
              }
              className={preventiviUrgenti > 0 ? "border-red-500" : "border-orange-300"}
              href={hrefConFiltro("da_preventivare")}
              attiva={filtroAttivo === "da_preventivare"}
            />
            <DashboardFilterCard
              titolo="Preventivi in attesa"
              valore={preventiviInAttesa}
              descrizione="Offerte inviate ancora senza esito definitivo"
              className="border-sky-300"
              href={hrefConFiltro("preventivi_in_attesa")}
              attiva={filtroAttivo === "preventivi_in_attesa"}
            />
            <DashboardFilterCard
              titolo={`Preventivi emessi · ${mesi.etichettaCorrente}`}
              valore={preventiviMeseCorrente}
              descrizione="Tutti i preventivi inviati nel mese corrente"
              className="border-blue-400"
              href={hrefConFiltro("preventivi_mese_corrente")}
              attiva={
                filtroAttivo === "preventivi_mese_corrente" ||
                filtroAttivo === "preventivi_inviati"
              }
            />
            <DashboardFilterCard
              titolo="Da fatturare"
              valore={daFatturare}
              descrizione="Ordini acquisiti senza fattura"
              className="border-red-300"
              href={hrefConFiltro("da_fatturare")}
              attiva={filtroAttivo === "da_fatturare"}
            />
            <DashboardFilterCard
              titolo={`Fatture emesse · ${mesi.etichettaCorrente}`}
              valore={fattureMeseCorrente}
              descrizione="Pratiche fatturate nel mese corrente"
              className="border-green-300"
              href={hrefConFiltro("fatture_mese_corrente")}
              attiva={
                filtroAttivo === "fatture_mese_corrente" ||
                filtroAttivo === "fatturate"
              }
            />
          </div>
        </section>

        <section className="mt-5">
          <div className="mb-3 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
            <h2 className="text-sm font-bold uppercase tracking-wider text-slate-500">
              Mese precedente · sola lettura
            </h2>
            <p className="text-xs font-semibold text-slate-400">
              {mesi.etichettaPrecedente} · dati conservati, nessuna modifica consentita
            </p>
          </div>

          <div className="grid gap-4 sm:grid-cols-2">
            <DashboardFilterCard
              titolo="Preventivi mese precedente"
              valore={preventiviMesePrecedente}
              descrizione={`${mesi.etichettaPrecedente} · archivio consultabile`}
              className="border-slate-400"
              href={hrefConFiltro("preventivi_mese_precedente")}
              attiva={filtroAttivo === "preventivi_mese_precedente"}
              solaLettura
            />
            <DashboardFilterCard
              titolo="Fatture mese precedente"
              valore={fattureMesePrecedente}
              descrizione={`${mesi.etichettaPrecedente} · archivio consultabile`}
              className="border-slate-400"
              href={hrefConFiltro("fatture_mese_precedente")}
              attiva={filtroAttivo === "fatture_mese_precedente"}
              solaLettura
            />
          </div>
        </section>

        <section className="mt-5">
          <h2 className="mb-3 text-sm font-bold uppercase tracking-wider text-slate-500">
            Coda amministrativa
          </h2>

          <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-3">
            <DashboardFilterCard
              titolo="Richieste dati da inviare"
              valore={richiesteAmministrativeDaInviare}
              descrizione="Messaggio mirato già pronto per il cliente"
              className="border-amber-500"
              href={hrefConFiltro("admin_richieste_da_inviare")}
              attiva={filtroAttivo === "admin_richieste_da_inviare"}
            />
            <DashboardFilterCard
              titolo="In attesa dati cliente"
              valore={richiesteAmministrativeInviate}
              descrizione="Richiesta inviata, risposta amministrativa attesa"
              className="border-cyan-500"
              href={hrefConFiltro("admin_attesa_dati_cliente")}
              attiva={filtroAttivo === "admin_attesa_dati_cliente"}
            />
            <DashboardFilterCard
              titolo="Cliente riconosciuto"
              valore={clientiRiconosciuti}
              descrizione="Anagrafica individuata, verifica amministrativa da completare"
              className="border-blue-400"
              href={hrefConFiltro("admin_cliente_riconosciuto")}
              attiva={filtroAttivo === "admin_cliente_riconosciuto"}
            />
            <DashboardFilterCard
              titolo="Dati amministrativi mancanti"
              valore={datiAmministrativiMancanti}
              descrizione="Cliente da collegare o dati fiscali da integrare"
              className="border-amber-400"
              href={hrefConFiltro("admin_dati_mancanti")}
              attiva={filtroAttivo === "admin_dati_mancanti"}
            />
            <DashboardFilterCard
              titolo="Corrispondenza ambigua"
              valore={corrispondenzeAmbigue}
              descrizione="Più anagrafiche compatibili, scelta manuale necessaria"
              className="border-fuchsia-400"
              href={hrefConFiltro("admin_corrispondenza_ambigua")}
              attiva={filtroAttivo === "admin_corrispondenza_ambigua"}
            />
            <DashboardFilterCard
              titolo="Pronto per fatturazione"
              valore={prontiFatturazione}
              descrizione="Cliente collegato e dati fiscali completi"
              className="border-green-400"
              href={hrefConFiltro("admin_pronto_fatturazione")}
              attiva={filtroAttivo === "admin_pronto_fatturazione"}
            />
          </div>
        </section>

        <section className="mt-8 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-200 px-6 py-5">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <h2 className="text-lg font-bold text-slate-950">
                  {solaLettura ? "Archivio mensile" : "Coda operativa"}
                </h2>
                <p className="mt-1 text-sm text-slate-500">
                  {solaLettura
                    ? `${mesi.etichettaPrecedente} · consultazione senza accesso alle modifiche`
                    : "Assistenza e pratiche commerciali ordinate automaticamente per priorità"}
                </p>
                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <span className="text-xs font-semibold uppercase tracking-wide text-slate-400">
                    Filtro attivo:
                  </span>

                  <span className="inline-flex rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">
                    {labelFiltro(
                      filtroAttivo,
                      mesi.etichettaCorrente,
                      mesi.etichettaPrecedente
                    )}
                  </span>

                  {filtroAttivo !== "tutte" && (
                    <Link
                      href={hrefConFiltro("tutte")}
                      className="text-xs font-semibold text-blue-600 hover:text-blue-800"
                    >
                      Rimuovi filtro
                    </Link>
                  )}
                </div>
              </div>

              <div className="text-sm font-semibold text-slate-600">
                {praticheFiltrate.length}{" "}
                {praticheFiltrate.length === 1 ? "pratica" : "pratiche"}
              </div>
            </div>

            <form method="GET" className="mt-5 flex flex-col gap-2 lg:flex-row">
              {filtroAttivo !== "tutte" && (
                <input type="hidden" name="filtro" value={filtroAttivo} />
              )}

              <input
                type="search"
                name="cerca"
                defaultValue={cercaAttiva}
                placeholder="Cerca pratica, cliente, telefono, targa, veicolo..."
                autoComplete="off"
                className="min-w-0 flex-1 rounded-xl border border-slate-300 bg-white px-4 py-3 text-sm text-slate-900 outline-none transition placeholder:text-slate-400 focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
              />

              <button
                type="submit"
                className="rounded-xl bg-blue-600 px-5 py-3 text-sm font-bold text-white transition hover:bg-blue-700"
              >
                Cerca
              </button>

              {cercaAttiva && (
                <Link
                  href={hrefAzzeraRicerca}
                  className="rounded-xl border border-slate-300 bg-white px-5 py-3 text-center text-sm font-bold text-slate-700 transition hover:bg-slate-50"
                >
                  Azzera ricerca
                </Link>
              )}
            </form>

            {cercaAttiva && (
              <div className="mt-2 text-sm text-slate-600">
                Ricerca: <strong>{cercaAttiva}</strong> ·{" "}
                <strong>{praticheFiltrate.length}</strong>{" "}
                {praticheFiltrate.length === 1
                  ? "pratica trovata"
                  : "pratiche trovate"}
              </div>
            )}
          </div>

          {solaLettura && (
            <div className="border-b border-slate-200 bg-slate-100 px-6 py-3 text-sm font-semibold text-slate-700">
              Archivio in sola lettura: le pratiche sono visibili ma non possono
              essere aperte o modificate da questa sezione.
            </div>
          )}

          {praticheFiltrate.length === 0 && !errore ? (
            <div className="px-6 py-16 text-center">
              <div className="text-lg font-semibold text-slate-800">
                {cercaAttiva
                  ? "Nessuna pratica trovata"
                  : "Nessuna pratica presente"}
              </div>
              <p className="mt-2 text-sm text-slate-500">
                {cercaAttiva
                  ? `Nessun risultato per “${cercaAttiva}”.`
                  : "Il collegamento al database è attivo."}
              </p>
            </div>
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[1550px] text-left text-sm">
                <thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-4">Priorità</th>
                    <th className="px-4 py-4">Pratica</th>
                    <th className="px-4 py-4">Flusso</th>
                    <th className="px-4 py-4">Cliente</th>
                    <th className="px-4 py-4">Targa</th>
                    <th className="px-4 py-4">Veicolo</th>
                    <th className="px-4 py-4">Componente</th>
                    <th className="px-4 py-4">Stato</th>
                    <th className="px-4 py-4">Dettaglio</th>
                    <th className="px-4 py-4">Preventivo</th>
                    <th className="px-4 py-4">Fattura</th>
                    <th className="px-4 py-4">Creata</th>
                  </tr>
                </thead>

                <tbody className="divide-y divide-slate-100">
                  {praticheFiltrate.map((pratica) => (
                    <tr
                      key={pratica.id}
                      id={`pratica-${pratica.id}`}
                      className={`transition ${
                        pratica.coda === "ASSISTENZA PRIORITARIA"
                          ? "bg-red-50 hover:bg-red-100"
                          : attesaDaPreventivare(pratica)?.rowClass ||
                            attesaDaVerificare(pratica)?.rowClass ||
                            "hover:bg-slate-50"
                      }`}
                    >
                      <td className="px-4 py-4">
                        <span
                          className={`inline-flex min-w-8 justify-center rounded-full px-2 py-1 text-xs font-bold ${prioritaClass(
                            pratica
                          )}`}
                        >
                          {pratica.priorita}
                        </span>
                      </td>

                      <td className="px-4 py-4 font-semibold text-slate-950">
                        {solaLettura ? (
                          <span className="inline-flex flex-col px-2 py-1 -mx-2 -my-1">
                            <span>{pratica.codice_pratica}</span>
                            <span className="mt-1 text-[10px] font-bold uppercase tracking-wide text-slate-400">
                              Sola lettura
                            </span>
                          </span>
                        ) : (
                          <ApriPraticaConContesto
                            praticaId={pratica.id}
                            className="inline-flex flex-col rounded-lg px-2 py-1 -mx-2 -my-1 transition hover:bg-blue-50 hover:text-blue-700"
                          >
                            <span>{pratica.codice_pratica}</span>
                            <span className="mt-1 text-[10px] font-bold uppercase tracking-wide text-blue-600">
                              Apri pratica
                            </span>
                          </ApriPraticaConContesto>
                        )}
                      </td>

                      <td className="px-4 py-4">
                        {pratica.tipo_flusso === "assistenza" ? (
                          <span className="inline-flex rounded-full bg-purple-100 px-3 py-1 text-xs font-bold text-purple-800">
                            ASSISTENZA
                          </span>
                        ) : (
                          <span className="inline-flex rounded-full bg-blue-50 px-3 py-1 text-xs font-bold text-blue-700">
                            COMMERCIALE
                          </span>
                        )}
                      </td>

                      <td className="px-4 py-4">
                        <div className="font-medium text-slate-900">
                          {pratica.nome_cliente || "Cliente"}
                        </div>
                        <div className="text-xs text-slate-500">
                          {pratica.telefono || "—"}
                        </div>
                      </td>

                      <td className="px-4 py-4 font-mono font-semibold text-slate-900">
                        {pratica.targa || "—"}
                      </td>

                      <td className="px-4 py-4 text-slate-700">
                        {[pratica.marca_veicolo, pratica.modello_veicolo]
                          .filter(Boolean)
                          .join(" ") || "—"}
                      </td>

                      <td className="px-4 py-4 text-slate-700">
                        {pratica.tipo_componente || "—"}
                      </td>

                      <td className="px-4 py-4">
                        <div className="flex flex-col items-start gap-2">
                          <span
                            className={`inline-flex rounded-full px-3 py-1 text-xs font-bold ${badgeClass(
                              pratica.coda
                            )}`}
                          >
                            {pratica.coda}
                          </span>

                          {attesaDaPreventivare(pratica) && (
                            <span
                              className={`inline-flex rounded-full px-3 py-1 text-[10px] font-bold uppercase tracking-wide ${
                                attesaDaPreventivare(pratica)!.badgeClass
                              }`}
                              title={`Ingresso in Da preventivare: ${formattaData(
                                pratica.da_preventivare_at || null
                              )}`}
                            >
                              {attesaDaPreventivare(pratica)!.label}
                            </span>
                          )}

                          {attesaDaVerificare(pratica) && (
                            <span
                              className={`inline-flex rounded-full px-3 py-1 text-[10px] font-bold uppercase tracking-wide ${
                                attesaDaVerificare(pratica)!.badgeClass
                              }`}
                              title={`Ingresso in Da verificare: ${formattaData(
                                pratica.da_verificare_at || null
                              )}`}
                            >
                              {attesaDaVerificare(pratica)!.label}
                            </span>
                          )}

                          {statoConfermaClienteVisuale(pratica) === "confermato" && (
                            <span className="inline-flex rounded-full bg-green-100 px-3 py-1 text-[10px] font-bold uppercase tracking-wide text-green-800">
                              Dati confermati dal cliente
                            </span>
                          )}

                          {pratica.stato_fatturazione === "da_fatturare" &&
                            pratica.stato_amministrativo && (
                              <span className="inline-flex rounded-full bg-indigo-50 px-3 py-1 text-[10px] font-bold uppercase tracking-wide text-indigo-800">
                                {pratica.stato_amministrativo === "cliente_riconosciuto"
                                  ? "Cliente riconosciuto"
                                  : pratica.stato_amministrativo === "dati_mancanti"
                                  ? "Dati amministrativi mancanti"
                                  : pratica.stato_amministrativo === "corrispondenza_ambigua"
                                  ? "Corrispondenza ambigua"
                                  : pratica.stato_amministrativo === "pronto_fatturazione"
                                  ? "Pronto per fatturazione"
                                  : "Amministrazione da verificare"}
                              </span>
                            )}

                          {pratica.stato_richiesta_amministrativa === "da_inviare" && (
                            <span className="inline-flex rounded-full bg-amber-100 px-3 py-1 text-[10px] font-bold uppercase tracking-wide text-amber-900">
                              Richiesta dati pronta
                            </span>
                          )}

                          {pratica.stato_richiesta_amministrativa === "inviata" && (
                            <span className="inline-flex rounded-full bg-cyan-100 px-3 py-1 text-[10px] font-bold uppercase tracking-wide text-cyan-900">
                              In attesa dati cliente
                            </span>
                          )}

                          {(pratica.attivita_operative || []).map((attivita) => (
                            <span
                              key={attivita.id}
                              title={attivita.evidenza}
                              className={`inline-flex rounded-full px-3 py-1 text-[10px] font-bold uppercase tracking-wide ${
                                attivita.tipo === "ritiro_programma_scambio"
                                  ? "bg-amber-100 text-amber-900"
                                  : attivita.tipo === "richiamata_post_preventivo"
                                  ? "bg-sky-100 text-sky-900"
                                  : attivita.tipo === "richiamata_post_vendita"
                                  ? "bg-violet-100 text-violet-900"
                                  : "bg-slate-200 text-slate-800"
                              }`}
                            >
                              {etichettaAttivita(attivita.tipo)}
                              {attivita.stato === "da_collegare" ? " · verifica collegamento" : ""}
                            </span>
                          ))}
                        </div>
                      </td>

                      <td className="max-w-[320px] px-4 py-4 text-slate-700">
                        {pratica.tipo_flusso === "assistenza" ? (
                          <div>
                            <div className="font-semibold">
                              {testoTipoAssistenza(pratica.tipo_assistenza)}
                            </div>
                            <div className="mt-1 text-xs text-slate-500">
                              {testoStatoAssistenza(pratica.stato_assistenza)}
                              {pratica.priorita_assistenza === "urgente" &&
                                " · URGENTE"}
                              {pratica.priorita_assistenza === "alta" &&
                                " · PRIORITÀ ALTA"}
                            </div>
                          </div>
                        ) : (
                          <div>
                            <div>{pratica.nota_incompletezza || "—"}</div>

                            {pratica.coda ===
                              "RICHIESTE VERIFICHE - ATTESA CLIENTE" && (
                              <div className="mt-1 text-xs font-semibold text-cyan-700">
                                Verifiche richieste al cliente · in attesa di risposta
                              </div>
                            )}

                            {pratica.coda === "DA PREVENTIVARE" &&
                              pratica.da_preventivare_at && (
                                <div className="mt-1 text-xs font-semibold text-slate-500">
                                  Da preventivare dal {formattaData(pratica.da_preventivare_at)}
                                </div>
                              )}

                            {pratica.coda === "DATI INTEGRATI - DA VERIFICARE" &&
                              pratica.da_verificare_at && (
                                <div className="mt-1 text-xs font-semibold text-slate-500">
                                  Da verificare dal {formattaData(pratica.da_verificare_at)}
                                </div>
                              )}

                            {statoConfermaClienteVisuale(pratica) ===
                              "confermato" &&
                              pratica.conferma_cliente_at && (
                                <div className="mt-1 text-xs font-semibold text-green-700">
                                  Confermato dal cliente ·{" "}
                                  {formattaData(pratica.conferma_cliente_at)}
                                </div>
                              )}
                          </div>
                        )}
                      </td>

                      <td className="px-4 py-4 font-semibold text-slate-900">
                        {formattaImporto(pratica.ultimo_importo_preventivo)}
                      </td>

                      <td className="px-4 py-4">
                        {pratica.numero_fattura ||
                        pratica.stato_fatturazione === "fatturato" ? (
                          <div>
                            <div className="font-semibold text-green-700">
                              {pratica.numero_fattura || "FATTURATA"}
                            </div>
                            <div className="text-xs text-slate-500">
                              {formattaData(dataFatturaEffettiva(pratica))}
                            </div>
                          </div>
                        ) : pratica.stato_fatturazione === "da_fatturare" ? (
                          <span className="font-bold text-red-700">
                            DA EMETTERE
                          </span>
                        ) : (
                          "—"
                        )}
                      </td>

                      <td className="px-4 py-4 text-slate-500">
                        {formattaData(pratica.created_at)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>

        <footer className="mt-6 text-center text-xs text-slate-400">
          Italiana Ricambi · Dashboard Operatore
        </footer>
      </div>
    </main>
    </ContestoNavigazioneElenco>
  );
}

function DashboardFilterCard({
  titolo,
  valore,
  descrizione,
  className,
  href,
  attiva,
  solaLettura = false,
}: {
  titolo: string;
  valore: number;
  descrizione: string;
  className: string;
  href: string;
  attiva: boolean;
  solaLettura?: boolean;
}) {
  return (
    <Link
      href={href}
      className={`block rounded-2xl border-t-4 bg-white p-5 shadow-sm transition hover:-translate-y-0.5 hover:shadow-md ${
        attiva ? "ring-2 ring-slate-300" : ""
      } ${className}`}
    >
      <div className="flex items-start justify-between gap-3">
        <div className="text-sm font-semibold text-slate-600">{titolo}</div>
        <span
          className={`text-[10px] font-bold uppercase tracking-wide ${
            solaLettura ? "text-slate-500" : "text-blue-600"
          }`}
        >
          {solaLettura ? "Consulta" : "Filtra"}
        </span>
      </div>

      <div className="mt-2 text-4xl font-bold tracking-tight text-slate-950">
        {valore}
      </div>

      <div className="mt-2 text-xs leading-5 text-slate-500">
        {descrizione}
      </div>
    </Link>
  );
}
