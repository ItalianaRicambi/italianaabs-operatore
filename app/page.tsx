import Link from "next/link";

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
};


function correggiCodaOperativa(pratica: Pratica): Pratica {
  // Le code assistenza sono già corrette nella view e restano intatte.
  if (pratica.tipo_flusso === "assistenza") {
    return pratica;
  }

  let coda = pratica.coda;
  let priorita = pratica.priorita;

  // Stato terminale: il rifiuto prevale su qualunque altro dato storico.
  if (pratica.stato_commerciale === "rifiutato") {
    coda = "RIFIUTATA";
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
  } else if (pratica.stato_completezza === "completa_da_preventivare") {
    // Il preventivo è il primo lavoro commerciale da eseguire dopo le urgenze assolute.
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
  errore: string | null;
}> {
  const url = process.env.SUPABASE_URL;
  const secretKey = process.env.SUPABASE_SECRET_KEY;

  if (!url || !secretKey) {
    return {
      pratiche: [],
      errore: "Variabili Supabase non configurate",
    };
  }

  try {
    const response = await fetch(
      `${url}/rest/v1/v_coda_operatore?select=*&order=priorita.asc,created_at.asc`,
      {
        headers: {
          apikey: secretKey,
        },
        cache: "no-store",
      }
    );

    if (!response.ok) {
      const dettaglio = await response.text();
      return {
        pratiche: [],
        errore: `Errore Supabase ${response.status}: ${dettaglio}`,
      };
    }

    const praticheBase = (await response.json()) as Pratica[];

    // I campi di conferma cliente sono stati aggiunti a public.pratiche
    // dopo la creazione della view v_coda_operatore.
    // Li leggiamo separatamente e li uniamo per id, senza toccare la view.
    const metaResponse = await fetch(
      `${url}/rest/v1/pratiche?select=id,fonte_completezza,stato_conferma_cliente,conferma_cliente_at,da_preventivare_at`,
      {
        headers: {
          apikey: secretKey,
          Authorization: `Bearer ${secretKey}`,
        },
        cache: "no-store",
      }
    );

    if (!metaResponse.ok) {
      // La dashboard deve continuare a funzionare anche se i soli
      // metadati di conferma cliente non fossero temporaneamente leggibili.
      console.error(
        "Metadati conferma cliente non disponibili:",
        metaResponse.status,
        await metaResponse.text()
      );

      return {
        pratiche: ordinaCodaOperativa(
          praticheBase.map(correggiCodaOperativa)
        ),
        errore: null,
      };
    }

    const metadati = (await metaResponse.json()) as Array<{
      id: string;
      fonte_completezza: string | null;
      stato_conferma_cliente:
        | "non_richiesta"
        | "in_attesa"
        | "confermato"
        | null;
      conferma_cliente_at: string | null;
      da_preventivare_at: string | null;
    }>;

    const metadatiPerId = new Map(
      metadati.map((riga) => [riga.id, riga])
    );

    const praticheComplete = praticheBase.map((pratica) => {
      const meta = metadatiPerId.get(pratica.id);

      return meta
        ? {
            ...pratica,
            fonte_completezza: meta.fonte_completezza,
            stato_conferma_cliente: meta.stato_conferma_cliente,
            conferma_cliente_at: meta.conferma_cliente_at,
            da_preventivare_at: meta.da_preventivare_at,
          }
        : pratica;
    });

    const praticheCorrette = ordinaCodaOperativa(
      praticheComplete.map(correggiCodaOperativa)
    );

    return {
      pratiche: praticheCorrette,
      errore: null,
    };
  } catch (error) {
    return {
      pratiche: [],
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

function contaAssistenzaAperta(pratiche: Pratica[]) {
  return pratiche.filter(
    (pratica) =>
      pratica.tipo_flusso === "assistenza" &&
      !["risolta", "chiusa"].includes(pratica.stato_assistenza)
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

function formattaData(data: string | null) {
  if (!data) return "—";
  return new Intl.DateTimeFormat("it-IT", {
    dateStyle: "short",
    timeStyle: "short",
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
  if (pratica.coda !== "DA PREVENTIVARE" || !pratica.da_preventivare_at) {
    return null;
  }

  const inizio = new Date(pratica.da_preventivare_at).getTime();
  if (!Number.isFinite(inizio)) return null;

  const minuti = Math.max(0, Math.floor((Date.now() - inizio) / 60000));
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
      label: `URGENTE · in attesa da ${durata}`,
      badgeClass: "bg-red-100 text-red-800 ring-1 ring-red-200",
      rowClass: "bg-red-50/70 hover:bg-red-100",
    };
  }

  if (minuti >= 30) {
    return {
      minuti,
      durata,
      livello: "attenzione" as const,
      label: `ATTENZIONE · in attesa da ${durata}`,
      badgeClass: "bg-amber-100 text-amber-900 ring-1 ring-amber-200",
      rowClass: "bg-amber-50/60 hover:bg-amber-100",
    };
  }

  return {
    minuti,
    durata,
    livello: "normale" as const,
    label: `In attesa da ${durata}`,
    badgeClass: "bg-green-100 text-green-800 ring-1 ring-green-200",
    rowClass: "hover:bg-slate-50",
  };
}

function statoConfermaClienteVisuale(
  pratica: Pratica
): "non_richiesta" | "in_attesa" | "confermato" {
  // La conferma cliente è utile solo nelle fasi operative iniziali.
  // Da preventivo inviato in avanti non deve più comparire come avviso,
  // perché la pratica è già passata a una fase commerciale successiva.
  const faseInizialeCommerciale =
    pratica.tipo_flusso === "commerciale" &&
    ["raccolta_dati", "richiesta_verifica", "da_preventivare"].includes(
      pratica.stato_commerciale ?? ""
    );

  if (!faseInizialeCommerciale) {
    return "non_richiesta";
  }

  if (pratica.stato_conferma_cliente === "confermato") {
    return "confermato";
  }

  if (pratica.stato_conferma_cliente === "in_attesa") {
    return "in_attesa";
  }

  // Finché non modifichiamo upsert_keplero_live, una pratica commerciale
  // completata dall'AI viene mostrata come "in attesa" se non esiste
  // ancora una conferma esplicita del cliente.
  if (
    ["completa_da_preventivare", "dati_integrati_da_verificare"].includes(
      pratica.stato_completezza ?? ""
    ) &&
    pratica.fonte_completezza === "ai"
  ) {
    return "in_attesa";
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


function filtraPratiche(pratiche: Pratica[], filtro: string) {
  switch (filtro) {
    case "assistenza_aperta":
      return pratiche.filter(
        (pratica) =>
          pratica.tipo_flusso === "assistenza" &&
          !["risolta", "chiusa"].includes(pratica.stato_assistenza)
      );

    case "assistenza_prioritaria":
      return pratiche.filter(
        (pratica) =>
          pratica.tipo_flusso === "assistenza" &&
          pratica.priorita_assistenza === "urgente" &&
          !["risolta", "chiusa"].includes(pratica.stato_assistenza)
      );

    case "dati_mancanti":
      return pratiche.filter((pratica) => pratica.coda === "DATI MANCANTI");

    case "da_verificare":
      return pratiche.filter(
        (pratica) => pratica.coda === "DATI INTEGRATI - DA VERIFICARE"
      );

    case "da_preventivare":
      return pratiche.filter((pratica) => pratica.coda === "DA PREVENTIVARE");

    case "preventivi_inviati":
      return pratiche.filter((pratica) => pratica.coda === "PREVENTIVO INVIATO");

    case "da_fatturare":
      return pratiche.filter(
        (pratica) => pratica.coda === "ORDINE ACQUISITO - DA FATTURARE"
      );

    case "fatturate":
      return pratiche.filter((pratica) => pratica.coda === "FATTURATA");

    default:
      return pratiche;
  }
}

function labelFiltro(filtro: string) {
  switch (filtro) {
    case "assistenza_aperta":
      return "Assistenza aperta";
    case "assistenza_prioritaria":
      return "Assistenza prioritaria";
    case "dati_mancanti":
      return "Dati mancanti";
    case "da_verificare":
      return "Da verificare";
    case "da_preventivare":
      return "Da preventivare";
    case "preventivi_inviati":
      return "Preventivi inviati";
    case "da_fatturare":
      return "Da fatturare";
    case "fatturate":
      return "Fatturati";
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
  const { pratiche, errore } = await getPratiche();
  const params = await searchParams;

  const filtroAttivo = Array.isArray(params?.filtro)
    ? params.filtro[0]
    : params?.filtro || "tutte";

  const cercaAttiva = (
    Array.isArray(params?.cerca)
      ? params.cerca[0]
      : params?.cerca || ""
  ).trim();

  const praticheFiltratePerStato = filtraPratiche(pratiche, filtroAttivo);
  const termineRicerca = cercaAttiva.toLowerCase();

  const praticheFiltrate = termineRicerca
    ? praticheFiltratePerStato.filter((pratica) =>
        Object.values(pratica).some((valore) =>
          String(valore ?? "").toLowerCase().includes(termineRicerca)
        )
      )
    : praticheFiltratePerStato;

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

  const assistenzaAperta = contaAssistenzaAperta(pratiche);
  const assistenzaPrioritaria = contaAssistenzaPrioritaria(pratiche);

  const datiMancanti = conta(pratiche, "DATI MANCANTI");
  const daVerificare = conta(pratiche, "DATI INTEGRATI - DA VERIFICARE");
  const daPreventivare = conta(pratiche, "DA PREVENTIVARE");
  const preventiviUrgenti = pratiche.filter((pratica) => {
    const attesa = attesaDaPreventivare(pratica);
    return attesa?.livello === "urgente";
  }).length;
  const preventiviInviati = conta(pratiche, "PREVENTIVO INVIATO");
  const daFatturare = conta(pratiche, "ORDINE ACQUISITO - DA FATTURARE");
  const fatturate = conta(pratiche, "FATTURATA");

  return (
    <main className="min-h-screen bg-slate-50">
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

        <section className="mb-5">
          <h2 className="mb-3 text-sm font-bold uppercase tracking-wider text-slate-500">
            Assistenza / Post-vendita
          </h2>

          <div className="grid gap-4 sm:grid-cols-2">
            <DashboardFilterCard
              titolo="Assistenza aperta"
              valore={assistenzaAperta}
              descrizione="Richieste di assistenza ancora da gestire o concludere"
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
            Commerciale / Amministrazione
          </h2>

          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 2xl:grid-cols-6">
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
              descrizione="Nuovi dati dopo intervento operatore"
              className="border-yellow-300"
              href={hrefConFiltro("da_verificare")}
              attiva={filtroAttivo === "da_verificare"}
            />
            <DashboardFilterCard
              titolo="Da preventivare"
              valore={daPreventivare}
              descrizione={
                preventiviUrgenti > 0
                  ? `${preventiviUrgenti} ${
                      preventiviUrgenti === 1 ? "pratica oltre 60 min" : "pratiche oltre 60 min"
                    }`
                  : "Dati completi, offerta da preparare"
              }
              className={preventiviUrgenti > 0 ? "border-red-500" : "border-orange-300"}
              href={hrefConFiltro("da_preventivare")}
              attiva={filtroAttivo === "da_preventivare"}
            />
            <DashboardFilterCard
              titolo="Preventivi inviati"
              valore={preventiviInviati}
              descrizione="Offerte inviate, in attesa di esito o follow-up"
              className="border-blue-400"
              href={hrefConFiltro("preventivi_inviati")}
              attiva={filtroAttivo === "preventivi_inviati"}
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
              titolo="Fatturati"
              valore={fatturate}
              descrizione="Pratiche amministrativamente completate"
              className="border-green-300"
              href={hrefConFiltro("fatturate")}
              attiva={filtroAttivo === "fatturate"}
            />
          </div>
        </section>

        <section className="mt-8 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
          <div className="border-b border-slate-200 px-6 py-5">
            <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <h2 className="text-lg font-bold text-slate-950">Coda operativa</h2>
                <p className="mt-1 text-sm text-slate-500">
                  Assistenza e pratiche commerciali ordinate automaticamente per priorità
                </p>
                <div className="mt-3 flex flex-wrap items-center gap-2">
                  <span className="text-xs font-semibold uppercase tracking-wide text-slate-400">
                    Filtro attivo:
                  </span>

                  <span className="inline-flex rounded-full bg-slate-100 px-3 py-1 text-xs font-semibold text-slate-700">
                    {labelFiltro(filtroAttivo)}
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
                      className={`transition ${
                        pratica.coda === "ASSISTENZA PRIORITARIA"
                          ? "bg-red-50 hover:bg-red-100"
                          : attesaDaPreventivare(pratica)?.rowClass ||
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
                        <Link
                          href={`/pratica/${pratica.id}`}
                          className="inline-flex flex-col rounded-lg px-2 py-1 -mx-2 -my-1 transition hover:bg-blue-50 hover:text-blue-700"
                        >
                          <span>{pratica.codice_pratica}</span>
                          <span className="mt-1 text-[10px] font-bold uppercase tracking-wide text-blue-600">
                            Apri pratica
                          </span>
                        </Link>
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

                          {statoConfermaClienteVisuale(pratica) === "in_attesa" && (
                            <span className="inline-flex rounded-full bg-amber-100 px-3 py-1 text-[10px] font-bold uppercase tracking-wide text-amber-900">
                              Dati non confermati dal cliente
                            </span>
                          )}

                          {statoConfermaClienteVisuale(pratica) === "confermato" && (
                            <span className="inline-flex rounded-full bg-green-100 px-3 py-1 text-[10px] font-bold uppercase tracking-wide text-green-800">
                              Dati confermati dal cliente
                            </span>
                          )}
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

                            {pratica.coda === "DA PREVENTIVARE" &&
                              pratica.da_preventivare_at && (
                                <div className="mt-1 text-xs font-semibold text-slate-500">
                                  Da preventivare dal {formattaData(pratica.da_preventivare_at)}
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
                        {pratica.numero_fattura ? (
                          <div>
                            <div className="font-semibold text-green-700">
                              {pratica.numero_fattura}
                            </div>
                            <div className="text-xs text-slate-500">
                              {pratica.data_fattura || ""}
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
  );
}

function DashboardFilterCard({
  titolo,
  valore,
  descrizione,
  className,
  href,
  attiva,
}: {
  titolo: string;
  valore: number;
  descrizione: string;
  className: string;
  href: string;
  attiva: boolean;
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
        <span className="text-[10px] font-bold uppercase tracking-wide text-blue-600">
          Filtra
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
