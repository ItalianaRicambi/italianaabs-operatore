import Link from "next/link";
import { notFound } from "next/navigation";
import {
  aggiungiCodiceOperatore,
  aggiungiDtcOperatore,
  aggiornaDatiPraticaOperatore,
  applicaAzioneOperatore,
  correggiStatoCommercialeOperatore,
  verificaCodiceOperatore,
  verificaDtcOperatore,
} from "./actions";

type RawCode = {
  codice?: string;
  fonte?: string;
  verificato?: boolean;
};

type RawAttachment = {
  url?: string;
  nome?: string;
  tipo?: string;
  timestamp?: string;
};

type RawMessage = {
  sender?: string;
  operator?: string | null;
  message?: string;
  timestamp?: string;
};

type Pratica = {
  id: string;
  numero_pratica?: number | null;
  keplero_conversation_id?: string | null;
  created_at: string;
  telefono?: string | null;
  nome_cliente?: string | null;
  targa?: string | null;
  marca_veicolo?: string | null;
  modello_veicolo?: string | null;
  tipo_componente?: string | null;
  tipo_guasto?: string | null;
  descrizione_guasto?: string | null;
  campi_bloccati_operatore?: string[] | null;
  stato_completezza?: string | null;
  fonte_completezza?: string | null;
  stato_conferma_cliente?: "non_richiesta" | "in_attesa" | "confermato" | null;
  conferma_cliente_at?: string | null;
  stato_commerciale?: string | null;
  stato_fatturazione?: string | null;
  stato_followup?: string | null;
  motivo_incompletezza?: string | null;
  nota_incompletezza?: string | null;
  tipo_flusso?: string | null;
  stato_assistenza?: string | null;
  tipo_assistenza?: string | null;
  priorita_assistenza?: string | null;
  nota_assistenza?: string | null;
  fonte_classificazione?: string | null;
  blocco_classificazione_operatore?: boolean | null;
  preventivo_inviato_at?: string | null;
  ordine_acquisito_at?: string | null;
  followup_previsto_at?: string | null;
  assistenza_aperta_at?: string | null;
  assistenza_chiusa_at?: string | null;
  stato_logistica?: string | null;
  ritiro_richiesto_at?: string | null;
  ritiro_programmato_at?: string | null;
  ultimo_messaggio_cliente_at?: string | null;
  dati_raw?: Record<string, unknown> | null;
};

type Codice = {
  id?: string;
  tipo_codice?: string | null;
  codice?: string | null;
  completo?: boolean | null;
  verificato_operatore?: boolean | null;
  fonte?: string | null;
  note?: string | null;
};

type Allegato = {
  id?: string;
  tipo?: string | null;
  url?: string | null;
  leggibile?: boolean | null;
  verificato_operatore?: boolean | null;
  fonte?: string | null;
};

type AzioneStorico = {
  id: number;
  azione: string;
  nota?: string | null;
  created_at: string;
};

type VerificaCodice = {
  id: number;
  codice: string;
  codice_normalizzato: string;
  esito: "confermato" | "scartato";
  updated_at: string;
};

type CodiceOperatore = {
  id: number;
  tipo_codice: string;
  codice: string;
  codice_normalizzato: string;
  fonte: string;
  note?: string | null;
  created_at: string;
};

type Dtc = {
  id: string;
  codice: string;
  descrizione?: string | null;
  fonte: string;
  esito: string;
  created_at: string;
};

function getSupabase() {
  const url = process.env.SUPABASE_URL;
  const secretKey = process.env.SUPABASE_SECRET_KEY;

  if (!url || !secretKey) {
    throw new Error("Variabili Supabase non configurate");
  }

  return { url, secretKey };
}

async function selectSupabase<T>(path: string): Promise<T> {
  const { url, secretKey } = getSupabase();

  const response = await fetch(`${url}/rest/v1/${path}`, {
    headers: {
      apikey: secretKey,
      Authorization: `Bearer ${secretKey}`,
    },
    cache: "no-store",
  });

  if (!response.ok) {
    const dettaglio = await response.text();
    throw new Error(`Supabase ${response.status}: ${dettaglio}`);
  }

  return (await response.json()) as T;
}

async function getPratica(id: string) {
  const pratiche = await selectSupabase<Pratica[]>(
    `pratiche?id=eq.${encodeURIComponent(id)}&select=*`
  );

  if (!pratiche.length) {
    notFound();
  }

  const [
    codici,
    allegati,
    storicoOperatore,
    verificheCodici,
    codiciOperatore,
    dtc,
  ] = await Promise.all([
    selectSupabase<Codice[]>(
      `codici_identificativi?pratica_id=eq.${encodeURIComponent(id)}&select=*`
    ),
    selectSupabase<Allegato[]>(
      `allegati?pratica_id=eq.${encodeURIComponent(id)}&select=*`
    ),
    selectSupabase<AzioneStorico[]>(
      `azioni_operatore?pratica_id=eq.${encodeURIComponent(
        id
      )}&select=id,azione,nota,created_at&order=created_at.desc`
    ),
    selectSupabase<VerificaCodice[]>(
      `verifiche_codici_operatore?pratica_id=eq.${encodeURIComponent(
        id
      )}&select=id,codice,codice_normalizzato,esito,updated_at`
    ),
    selectSupabase<CodiceOperatore[]>(
      `codici_operatore?pratica_id=eq.${encodeURIComponent(
        id
      )}&select=id,tipo_codice,codice,codice_normalizzato,fonte,note,created_at&order=created_at.asc`
    ),
    selectSupabase<Dtc[]>(
      `dtc?pratica_id=eq.${encodeURIComponent(
        id
      )}&select=id,codice,descrizione,fonte,esito,created_at&order=created_at.asc`
    ),
  ]);

  return {
    pratica: pratiche[0],
    codici,
    allegati,
    storicoOperatore,
    verificheCodici,
    codiciOperatore,
    dtc,
  };
}

function formattaData(data?: string | null) {
  if (!data) return "—";

  return new Intl.DateTimeFormat("it-IT", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date(data));
}

function leggibile(value: unknown) {
  if (value === null || value === undefined || value === "") return "—";
  if (typeof value === "boolean") return value ? "Sì" : "No";
  return String(value);
}

function codicePratica(pratica: Pratica) {
  if (pratica.numero_pratica) {
    return `ABS-${String(pratica.numero_pratica).padStart(6, "0")}`;
  }

  return pratica.id.slice(0, 8).toUpperCase();
}

function titoloAssistenza(tipo?: string | null) {
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


function etichettaConfermaCliente(value?: string | null) {
  switch (value) {
    case "in_attesa":
      return "Dati non confermati dal cliente";
    case "confermato":
      return "Dati confermati dal cliente";
    case "non_richiesta":
      return "Conferma non richiesta";
    default:
      return "—";
  }
}

function etichettaStato(value?: string | null) {
  if (!value) return "—";

  const labels: Record<string, string> = {
    dati_mancanti: "Dati mancanti",
    completa_da_preventivare: "Completa / da preventivare",
    completa: "Completa",
    raccolta_dati: "Raccolta dati",
    da_preventivare: "Da preventivare",
    preventivo_inviato: "Preventivo inviato",
    ordine_acquisito: "Ordine acquisito",
    non_applicabile: "Non applicabile",
    da_fatturare: "Da fatturare",
    fatturato: "Fatturata",
    non_previsto: "Non previsto",
    previsto: "Previsto",
    da_verificare: "Da verificare",
    in_gestione: "In gestione",
    attesa_cliente: "Attesa cliente",
    attesa_rientro: "Attesa rientro",
    risolta: "Risolta",
    chiusa: "Chiusa",
    richiesta_verifica: "Richiesta verifiche",
    rifiutato: "Rifiutata",
    ritiro_richiesto: "Ritiro richiesto",
    ritiro_programmato: "Ritiro programmato",
    ritirato: "Ritirato",
    urgente: "Urgente",
    alta: "Alta",
    normale: "Normale",
    ai: "AI",
    operatore: "Operatore",
    cliente: "Cliente",
  };

  if (labels[value]) return labels[value];

  return value
    .replace(/_/g, " ")
    .replace(/\b\w/g, (lettera) => lettera.toUpperCase());
}

function etichettaAzione(azione: string) {
  const labels: Record<string, string> = {
    assistenza_in_gestione: "Pratica presa in carico",
    assistenza_attesa_cliente: "Messa in attesa cliente",
    assistenza_attesa_rientro: "Messa in attesa rientro",
    assistenza_risolta: "Assistenza segnata come risolta",
    commerciale_dati_mancanti: "Segnata come dati mancanti",
    commerciale_dati_verificati: "Dati verificati / da preventivare",
    commerciale_preventivo_inviato: "Preventivo segnato come inviato",
    commerciale_ordine_acquisito: "Ordine segnato come acquisito",
    commerciale_fatturata: "Pratica segnata come fatturata",
    operatore_non_assistenza: "Riclassificata: non è assistenza",
    commerciale_richiesta_verifica: "Messa in richiesta verifiche / attesa risposta",
    commerciale_rifiuta_lavorazione: "Lavorazione rifiutata",
    logistica_ritiro_richiesto: "Ritiro richiesto",
    logistica_ritiro_programmato: "Ritiro programmato",
    logistica_ritirato: "Componente segnato come ritirato",
    logistica_annulla_ritiro: "Ritiro annullato",
    codice_confermato: "Codice identificativo confermato",
    codice_scartato: "Codice identificativo scartato",
    codice_aggiunto_operatore: "Codice corretto aggiunto dall’operatore",
    operatore_correzione_stato: "Stato corretto manualmente dall’operatore",
  };

  return labels[azione] || etichettaStato(azione);
}

function rawArray<T>(raw: Record<string, unknown> | null | undefined, key: string): T[] {
  const value = raw?.[key];
  return Array.isArray(value) ? (value as T[]) : [];
}

function rawString(raw: Record<string, unknown> | null | undefined, key: string) {
  const value = raw?.[key];
  return typeof value === "string" && value.trim() ? value : null;
}

export default async function PraticaPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const {
    pratica,
    codici,
    allegati,
    storicoOperatore,
    verificheCodici,
    codiciOperatore,
    dtc,
  } = await getPratica(id);

  const rawCodes = rawArray<RawCode>(
    pratica.dati_raw,
    "codici_identificativi_estratti"
  );
  const rawAttachments = rawArray<RawAttachment>(
    pratica.dati_raw,
    "allegati_keplero"
  );
  const rawMessages = rawArray<RawMessage>(
    pratica.dati_raw,
    "messaggi_keplero"
  );

  const ultimoClienteUtile = rawString(
    pratica.dati_raw,
    "ultimo_messaggio_cliente_utile"
  );
  const riepilogoOperativo = rawString(
    pratica.dati_raw,
    "riepilogo_operativo"
  );

  const verifichePerCodice = new Map(
    verificheCodici.map((item) => [
      item.codice_normalizzato,
      item.esito,
    ])
  );

  function normalizzaCodiceUi(codice: string) {
    return codice.trim().toUpperCase().replace(/\s+/g, "");
  }

  function esitoCodice(codice: string) {
    const conSpazi = codice.trim().toUpperCase();
    const compatto = normalizzaCodiceUi(codice);

    return (
      verifichePerCodice.get(compatto) ||
      verifichePerCodice.get(conSpazi) ||
      null
    );
  }

  const codiciMappa = new Map<
    string,
    {
      codice: string;
      tipo: string;
      fonte: string;
      esito: "confermato" | "scartato" | null;
      note: string | null;
    }
  >();

  for (const item of codici) {
    const codice = (item.codice || "").trim();
    if (!codice) continue;

    const chiave = normalizzaCodiceUi(codice);

    codiciMappa.set(chiave, {
      codice,
      tipo: item.tipo_codice || "Identificativo",
      fonte: item.fonte || "Database",
      esito:
        esitoCodice(codice) ||
        (item.verificato_operatore ? "confermato" : null),
      note: item.note || null,
    });
  }

  for (const item of rawCodes) {
    const codice = (item.codice || "").trim();
    if (!codice) continue;

    const chiave = normalizzaCodiceUi(codice);

    if (!codiciMappa.has(chiave)) {
      codiciMappa.set(chiave, {
        codice,
        tipo: "Identificativo",
        fonte:
          item.fonte === "cliente"
            ? "Cliente"
            : "Estrazione automatica dalla chat",
        esito:
          esitoCodice(codice) ||
          (item.verificato ? "confermato" : null),
        note: null,
      });
    } else {
      const esistente = codiciMappa.get(chiave)!;
      esistente.esito = esitoCodice(codice) || esistente.esito;
    }
  }

  for (const item of codiciOperatore) {
    const codice = (item.codice || "").trim();
    if (!codice) continue;

    const chiave = normalizzaCodiceUi(codice);

    codiciMappa.set(chiave, {
      codice,
      tipo: item.tipo_codice || "Altro",
      fonte: "Operatore",
      esito: esitoCodice(codice) || "confermato",
      note: item.note || null,
    });
  }

  const codiciVisualizzati = Array.from(codiciMappa.values());

  const codiciConfermati = codiciVisualizzati.filter(
    (item) => item.esito === "confermato"
  ).length;

  const codiciScartati = codiciVisualizzati.filter(
    (item) => item.esito === "scartato"
  ).length;

  const codiciInAttesa = codiciVisualizzati.filter(
    (item) => !item.esito
  ).length;

  const codiciPronti =
    codiciVisualizzati.length > 0 &&
    codiciInAttesa === 0 &&
    codiciConfermati > 0;

  const dtcConfermati = dtc.filter(
    (item) => item.esito === "confermato"
  ).length;

  const dtcScartati = dtc.filter(
    (item) => item.esito === "scartato"
  ).length;

  const dtcInAttesa = dtc.filter(
    (item) => !["confermato", "scartato"].includes(item.esito)
  ).length;

  const statoConfermaClienteVisuale:
    | "non_richiesta"
    | "in_attesa"
    | "confermato" =
    pratica.stato_conferma_cliente === "confermato"
      ? "confermato"
      : pratica.stato_conferma_cliente === "in_attesa"
      ? "in_attesa"
      : pratica.tipo_flusso === "commerciale" &&
        pratica.stato_completezza === "completa_da_preventivare" &&
        pratica.fonte_completezza === "ai"
      ? "in_attesa"
      : "non_richiesta";

  const allegatiVisualizzati =
    allegati.length > 0
      ? allegati
          .filter((item) => item.url)
          .map((item) => ({
            url: item.url || "",
            tipo: item.tipo || "Allegato",
            nome: item.tipo || "Allegato",
            fonte: item.fonte || "database",
            leggibile: item.leggibile,
          }))
      : rawAttachments
          .filter((item) => item.url)
          .map((item) => ({
            url: item.url || "",
            tipo: item.tipo || "Allegato",
            nome: item.nome || item.tipo || "Allegato",
            fonte: "Keplero",
            leggibile: null,
          }));

  return (
    <main className="min-h-screen bg-slate-50">
      <div className="mx-auto max-w-[1500px] px-6 py-8">
        <div className="mb-6">
          <Link
            href="/"
            className="inline-flex items-center rounded-lg border border-slate-200 bg-white px-4 py-2 text-sm font-semibold text-slate-700 shadow-sm transition hover:bg-slate-50"
          >
            ← Torna alla dashboard
          </Link>
        </div>

        <header className="mb-6 rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
          <div className="flex flex-col gap-5 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p className="text-xs font-bold uppercase tracking-[0.18em] text-slate-500">
                Italiana Ricambi / ItalianaABS
              </p>

              <h1 className="mt-2 text-3xl font-bold tracking-tight text-slate-950">
                {codicePratica(pratica)}
              </h1>

              <p className="mt-2 text-sm text-slate-500">
                Creata {formattaData(pratica.created_at)}
              </p>
            </div>

            <div className="flex flex-wrap gap-2">
              <span
                className={`rounded-full px-4 py-2 text-xs font-bold ${
                  pratica.tipo_flusso === "assistenza"
                    ? "bg-purple-100 text-purple-800"
                    : "bg-blue-100 text-blue-800"
                }`}
              >
                {pratica.tipo_flusso === "assistenza"
                  ? "ASSISTENZA"
                  : "COMMERCIALE"}
              </span>

              {pratica.tipo_flusso === "commerciale" &&
                statoConfermaClienteVisuale !== "non_richiesta" && (
                  <span
                    className={`rounded-full px-4 py-2 text-xs font-bold ${
                      statoConfermaClienteVisuale === "confermato"
                        ? "bg-green-100 text-green-800"
                        : "bg-amber-100 text-amber-900"
                    }`}
                  >
                    {statoConfermaClienteVisuale === "confermato"
                      ? "DATI CONFERMATI DAL CLIENTE"
                      : "DATI NON CONFERMATI DAL CLIENTE"}
                  </span>
                )}

              {pratica.tipo_flusso === "assistenza" && (
                <span
                  className={`rounded-full px-4 py-2 text-xs font-bold ${
                    pratica.priorita_assistenza === "urgente"
                      ? "bg-red-100 text-red-800"
                      : pratica.priorita_assistenza === "alta"
                      ? "bg-orange-100 text-orange-800"
                      : "bg-slate-100 text-slate-700"
                  }`}
                >
                  PRIORITÀ {(pratica.priorita_assistenza || "normale").toUpperCase()}
                </span>
              )}
            </div>
          </div>
        </header>

        <div className="grid gap-6 xl:grid-cols-3">
          <section className="space-y-6 xl:col-span-2">
            <Card titolo="Cliente e veicolo">
              <div className="grid gap-4 sm:grid-cols-2">
                <Campo label="Cliente" value={pratica.nome_cliente} />
                <Campo label="Telefono" value={pratica.telefono} />
              </div>

              <div className="mt-6 border-t border-slate-200 pt-5">
                <div className="mb-4">
                  <div className="text-sm font-bold text-slate-900">
                    Dati pratica modificabili dall&apos;operatore
                  </div>
                  <p className="mt-1 text-xs leading-5 text-slate-500">
                    Correggi o completa i dati ricevuti da Keplero. Con il
                    salvataggio i valori presenti vengono confermati come dati
                    dell&apos;operatore e protetti dagli aggiornamenti automatici.
                  </p>
                </div>

                <form action={aggiornaDatiPraticaOperatore}>
                  <input type="hidden" name="pratica_id" value={pratica.id} />

                  <div className="grid gap-3 xl:grid-cols-[140px_1fr_1fr_160px]">
                    <div>
                      <label className="mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500">
                        Targa
                      </label>
                      <input
                        type="text"
                        name="targa"
                        defaultValue={pratica.targa || ""}
                        placeholder="Es. DE66571"
                        className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 font-mono text-sm font-semibold text-slate-900 outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                      />
                    </div>

                    <div>
                      <label className="mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500">
                        Marca
                      </label>
                      <input
                        type="text"
                        name="marca_veicolo"
                        defaultValue={pratica.marca_veicolo || ""}
                        placeholder="Es. BMW"
                        className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm font-semibold text-slate-900 outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                      />
                    </div>

                    <div>
                      <label className="mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500">
                        Modello
                      </label>
                      <input
                        type="text"
                        name="modello_veicolo"
                        defaultValue={pratica.modello_veicolo || ""}
                        placeholder="Es. R1200 GS"
                        className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm font-semibold text-slate-900 outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                      />
                    </div>

                    <div>
                      <label className="mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500">
                        Componente
                      </label>
                      <input
                        type="text"
                        name="tipo_componente"
                        defaultValue={pratica.tipo_componente || ""}
                        placeholder="Es. ABS"
                        className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm font-semibold text-slate-900 outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                      />
                    </div>
                  </div>

                  <div className="mt-3 grid gap-3 xl:grid-cols-[220px_1fr_auto] xl:items-end">
                    <div>
                      <label className="mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500">
                        Tipo guasto
                      </label>
                      <select
                        name="tipo_guasto"
                        defaultValue={pratica.tipo_guasto || ""}
                        className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm font-semibold text-slate-900 outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                      >
                        <option value="">Seleziona...</option>
                        <option value="idraulico_meccanico">
                          Idraulico / meccanico
                        </option>
                        <option value="elettrico_elettronico">
                          Elettrico / elettronico
                        </option>
                        <option value="non_definito">
                          Non definito / da verificare
                        </option>
                      </select>
                    </div>

                    <div>
                      <label className="mb-1 block text-xs font-bold uppercase tracking-wide text-slate-500">
                        Descrizione guasto
                      </label>
                      <input
                        type="text"
                        name="descrizione_guasto"
                        defaultValue={pratica.descrizione_guasto || ""}
                        placeholder="Es. rimane frenata la ruota posteriore destra"
                        className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-100"
                      />
                    </div>

                    <button
                      type="submit"
                      className="rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-bold text-white transition hover:bg-blue-700"
                    >
                      Salva e conferma
                    </button>
                  </div>
                </form>
              </div>
            </Card>

            <Card titolo="Problema / riepilogo operativo">
              {pratica.tipo_guasto && (
                <div className="mb-3">
                  <span className="inline-flex rounded-full bg-slate-100 px-3 py-1 text-xs font-bold text-slate-700">
                    Tipo guasto:{" "}
                    {pratica.tipo_guasto === "idraulico_meccanico"
                      ? "Idraulico / meccanico"
                      : pratica.tipo_guasto === "elettrico_elettronico"
                      ? "Elettrico / elettronico"
                      : "Non definito / da verificare"}
                  </span>
                </div>
              )}

              <p className="whitespace-pre-wrap text-sm leading-6 text-slate-800">
                {pratica.descrizione_guasto ||
                  riepilogoOperativo ||
                  "Nessuna descrizione disponibile."}
              </p>

              {ultimoClienteUtile && (
                <div className="mt-5 rounded-xl border border-blue-200 bg-blue-50 p-4">
                  <div className="mb-2 text-xs font-bold uppercase tracking-wide text-blue-600">
                    Ultimo messaggio cliente utile
                  </div>
                  <p className="whitespace-pre-wrap text-sm leading-6 text-slate-800">
                    {ultimoClienteUtile}
                  </p>
                </div>
              )}
            </Card>

            <Card titolo="Codici identificativi">
              <div className="mb-6 rounded-xl border border-blue-200 bg-blue-50 p-4">
                <div className="text-sm font-bold text-blue-900">
                  Aggiungi codice corretto
                </div>
                <p className="mt-1 text-xs leading-5 text-blue-800">
                  Se l’AI ha letto male un codice, scartalo e inserisci qui
                  quello corretto. Il nuovo codice viene registrato come
                  <strong> Operatore</strong> e confermato automaticamente.
                </p>

                <form
                  action={aggiungiCodiceOperatore}
                  className="mt-4 grid gap-3 md:grid-cols-[150px_1fr_auto]"
                >
                  <input
                    type="hidden"
                    name="pratica_id"
                    value={pratica.id}
                  />

                  <select
                    name="tipo_codice"
                    defaultValue="OE"
                    className="rounded-lg border border-blue-200 bg-white px-3 py-2 text-sm font-semibold text-slate-800"
                  >
                    <option value="OE">OE</option>
                    <option value="Bosch">Bosch</option>
                    <option value="ATE">ATE</option>
                    <option value="Identificativo">Identificativo</option>
                    <option value="Altro">Altro</option>
                  </select>

                  <input
                    type="text"
                    name="codice"
                    required
                    maxLength={100}
                    placeholder="Inserisci il codice corretto"
                    className="rounded-lg border border-blue-200 bg-white px-3 py-2 font-mono text-sm text-slate-900 outline-none focus:border-blue-500"
                  />

                  <button
                    type="submit"
                    className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-bold text-white transition hover:bg-blue-700"
                  >
                    Aggiungi e conferma
                  </button>
                </form>
              </div>

              {codiciVisualizzati.length ? (
                <>
                  <div className="mb-5 flex flex-wrap gap-2 text-xs font-bold">
                    <span className="rounded-full bg-green-100 px-3 py-1 text-green-800">
                      Confermati: {codiciConfermati}
                    </span>
                    <span className="rounded-full bg-red-100 px-3 py-1 text-red-800">
                      Scartati: {codiciScartati}
                    </span>
                    <span className="rounded-full bg-orange-100 px-3 py-1 text-orange-800">
                      Da verificare: {codiciInAttesa}
                    </span>
                  </div>

                  <div className="overflow-x-auto">
                    <table className="w-full text-left text-sm">
                      <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                        <tr>
                          <th className="py-3 pr-4">Tipo</th>
                          <th className="py-3 pr-4">Codice</th>
                          <th className="py-3 pr-4">Fonte</th>
                          <th className="py-3 pr-4">Esito</th>
                          <th className="py-3">Azioni</th>
                        </tr>
                      </thead>

                      <tbody className="divide-y divide-slate-100">
                        {codiciVisualizzati.map((codice, index) => (
                          <tr key={`${codice.codice}-${index}`}>
                            <td className="py-3 pr-4 text-slate-600">
                              {codice.tipo}
                            </td>

                            <td className="py-3 pr-4 font-mono font-bold text-slate-950">
                              {codice.codice}
                            </td>

                            <td className="py-3 pr-4 text-slate-600">
                              {codice.fonte === "Operatore" ? (
                                <span className="font-bold text-blue-700">
                                  Operatore
                                </span>
                              ) : (
                                codice.fonte
                              )}
                            </td>

                            <td className="py-3 pr-4">
                              {codice.esito === "confermato" ? (
                                <span className="font-bold text-green-700">
                                  ✓ Confermato
                                </span>
                              ) : codice.esito === "scartato" ? (
                                <span className="font-bold text-red-700">
                                  ✕ Scartato
                                </span>
                              ) : (
                                <span className="font-bold text-orange-700">
                                  Da verificare
                                </span>
                              )}
                            </td>

                            <td className="py-3">
                              <div className="flex flex-wrap gap-2">
                                <VerificaCodiceButton
                                  praticaId={pratica.id}
                                  codice={codice.codice}
                                  esito="confermato"
                                  label="✓ Conferma"
                                  disabilitato={
                                    codice.esito === "confermato"
                                  }
                                  className="bg-green-100 text-green-800 hover:bg-green-200"
                                />

                                <VerificaCodiceButton
                                  praticaId={pratica.id}
                                  codice={codice.codice}
                                  esito="scartato"
                                  label="✕ Scarta"
                                  disabilitato={codice.esito === "scartato"}
                                  className="bg-red-100 text-red-800 hover:bg-red-200"
                                />
                              </div>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </>
              ) : (
                <div className="rounded-xl border border-orange-200 bg-orange-50 p-4">
                  <p className="text-sm font-bold text-orange-900">
                    Nessun codice identificativo disponibile.
                  </p>
                  <p className="mt-1 text-sm leading-6 text-orange-800">
                    Per una pratica commerciale il preventivo resta bloccato
                    finché non è presente almeno un codice identificativo
                    confermato.
                  </p>
                </div>
              )}
            </Card>

            <Card titolo="DTC / codici guasto">
              <div className="mb-6 rounded-xl border border-red-200 bg-red-50 p-4">
                <div className="text-sm font-bold text-red-900">
                  Aggiungi DTC corretto
                </div>
                <p className="mt-1 text-xs leading-5 text-red-800">
                  Se Keplero ha letto male un codice guasto, scartalo e inserisci
                  qui quello corretto. Il nuovo DTC viene registrato come
                  <strong> Operatore</strong> e confermato automaticamente.
                </p>

                <form
                  action={aggiungiDtcOperatore}
                  className="mt-4 grid gap-3 md:grid-cols-[180px_1fr_auto]"
                >
                  <input
                    type="hidden"
                    name="pratica_id"
                    value={pratica.id}
                  />

                  <input
                    type="text"
                    name="codice"
                    required
                    maxLength={100}
                    placeholder="Es. C0035-5A"
                    className="rounded-lg border border-red-200 bg-white px-3 py-2 font-mono text-sm font-bold text-slate-900 outline-none focus:border-red-500"
                  />

                  <input
                    type="text"
                    name="descrizione"
                    maxLength={500}
                    placeholder="Descrizione del DTC (opzionale)"
                    className="rounded-lg border border-red-200 bg-white px-3 py-2 text-sm text-slate-900 outline-none focus:border-red-500"
                  />

                  <button
                    type="submit"
                    className="rounded-lg bg-red-600 px-4 py-2 text-sm font-bold text-white transition hover:bg-red-700"
                  >
                    Aggiungi e conferma
                  </button>
                </form>
              </div>

              {dtc.length ? (
                <>
                  <div className="mb-5 flex flex-wrap gap-2 text-xs font-bold">
                    <span className="rounded-full bg-green-100 px-3 py-1 text-green-800">
                      Confermati: {dtcConfermati}
                    </span>
                    <span className="rounded-full bg-red-100 px-3 py-1 text-red-800">
                      Scartati: {dtcScartati}
                    </span>
                    <span className="rounded-full bg-orange-100 px-3 py-1 text-orange-800">
                      Da verificare: {dtcInAttesa}
                    </span>
                  </div>

                  <div className="overflow-x-auto">
                    <table className="w-full text-left text-sm">
                      <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                        <tr>
                          <th className="py-3 pr-4">Codice</th>
                          <th className="py-3 pr-4">Descrizione</th>
                          <th className="py-3 pr-4">Fonte</th>
                          <th className="py-3 pr-4">Esito</th>
                          <th className="py-3">Azioni</th>
                        </tr>
                      </thead>

                      <tbody className="divide-y divide-slate-100">
                        {dtc.map((item, index) => (
                          <tr key={item.id || `${item.codice}-${index}`}>
                            <td className="py-3 pr-4 align-top font-mono font-bold text-slate-950">
                              {item.codice}
                            </td>

                            <td className="py-3 pr-4 align-top text-slate-700">
                              {item.descrizione || "—"}
                            </td>

                            <td className="py-3 pr-4 align-top text-slate-600">
                              {item.fonte === "operatore" ? (
                                <span className="font-bold text-blue-700">
                                  Operatore
                                </span>
                              ) : (
                                etichettaStato(item.fonte)
                              )}
                            </td>

                            <td className="py-3 pr-4 align-top">
                              {item.esito === "confermato" ? (
                                <span className="font-bold text-green-700">
                                  ✓ Confermato
                                </span>
                              ) : item.esito === "scartato" ? (
                                <span className="font-bold text-red-700">
                                  ✕ Scartato
                                </span>
                              ) : (
                                <span className="font-bold text-orange-700">
                                  Da verificare
                                </span>
                              )}
                            </td>

                            <td className="py-3 align-top">
                              <div className="flex flex-wrap gap-2">
                                <VerificaDtcButton
                                  praticaId={pratica.id}
                                  codice={item.codice}
                                  esito="confermato"
                                  label="✓ Conferma"
                                  disabilitato={item.esito === "confermato"}
                                  className="bg-green-100 text-green-800 hover:bg-green-200"
                                />

                                <VerificaDtcButton
                                  praticaId={pratica.id}
                                  codice={item.codice}
                                  esito="scartato"
                                  label="✕ Scarta"
                                  disabilitato={item.esito === "scartato"}
                                  className="bg-red-100 text-red-800 hover:bg-red-200"
                                />
                              </div>
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </>
              ) : (
                <div className="rounded-xl border border-slate-200 bg-slate-50 p-4">
                  <p className="text-sm font-bold text-slate-800">
                    Nessun DTC presente.
                  </p>
                  <p className="mt-1 text-sm leading-6 text-slate-600">
                    Nessun codice guasto è stato importato nella tabella DTC per
                    questa pratica.
                  </p>
                </div>
              )}
            </Card>

            <Card titolo="Allegati Keplero">
              {allegatiVisualizzati.length ? (
                <div className="grid gap-3 sm:grid-cols-2">
                  {allegatiVisualizzati.map((allegato, index) => (
                    <div
                      key={`${allegato.url}-${index}`}
                      className="rounded-xl border border-slate-200 bg-slate-50 p-4"
                    >
                      <div className="break-words text-sm font-bold text-slate-900">
                        {allegato.nome}
                      </div>

                      <div className="mt-1 text-xs text-slate-500">
                        Tipo: {allegato.tipo} · Fonte: {allegato.fonte}
                      </div>

                      <a
                        href={allegato.url}
                        target="_blank"
                        rel="noreferrer"
                        className="mt-3 inline-flex rounded-lg bg-slate-900 px-3 py-2 text-xs font-bold text-white transition hover:bg-slate-700"
                      >
                        Apri allegato
                      </a>
                    </div>
                  ))}
                </div>
              ) : (
                <p className="text-sm text-slate-500">
                  Nessun allegato presente nella conversazione esportata.
                </p>
              )}
            </Card>

            <Card titolo="Conversazione Keplero">
              {rawMessages.length ? (
                <details>
                  <summary className="cursor-pointer select-none text-sm font-bold text-blue-700">
                    Mostra conversazione completa ({rawMessages.length} messaggi)
                  </summary>

                  <div className="mt-5 space-y-3">
                    {rawMessages.map((messaggio, index) => (
                      <div
                        key={`${messaggio.timestamp}-${index}`}
                        className={`rounded-xl border p-4 ${
                          messaggio.sender === "user"
                            ? "border-blue-200 bg-blue-50"
                            : "border-slate-200 bg-slate-50"
                        }`}
                      >
                        <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                          <div className="text-xs font-bold uppercase tracking-wide text-slate-500">
                            {messaggio.sender === "user"
                              ? "Cliente"
                              : messaggio.operator
                              ? `Operatore: ${messaggio.operator}`
                              : "Keplero"}
                          </div>

                          <div className="text-xs text-slate-400">
                            {formattaData(messaggio.timestamp)}
                          </div>
                        </div>

                        <p className="break-words whitespace-pre-wrap text-sm leading-6 text-slate-800">
                          {messaggio.message}
                        </p>
                      </div>
                    ))}
                  </div>
                </details>
              ) : (
                <p className="text-sm text-slate-500">
                  Conversazione completa non ancora importata.
                </p>
              )}
            </Card>
          </section>

          <aside className="space-y-6">
            <Card titolo="Azioni operatore">
              <p className="mb-4 text-sm leading-6 text-slate-500">
                Usa questi pulsanti solo quando vuoi cambiare realmente lo stato
                della pratica. Ogni azione viene registrata nello storico.
              </p>

              {pratica.tipo_flusso === "assistenza" ? (
                <div className="grid gap-3">
                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="assistenza_in_gestione"
                    label="Prendi in carico"
                    className="bg-blue-600 text-white hover:bg-blue-700"
                    disabilitata={pratica.stato_assistenza === "in_gestione"}
                    motivoDisabilitata="Stato attuale"
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="assistenza_attesa_cliente"
                    label="Attesa cliente"
                    className="bg-amber-100 text-amber-900 hover:bg-amber-200"
                    disabilitata={pratica.stato_assistenza === "attesa_cliente"}
                    motivoDisabilitata="Stato attuale"
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="assistenza_attesa_rientro"
                    label="Attesa rientro"
                    className="bg-orange-100 text-orange-900 hover:bg-orange-200"
                    disabilitata={pratica.stato_assistenza === "attesa_rientro"}
                    motivoDisabilitata="Stato attuale"
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="assistenza_risolta"
                    label="Segna come risolta"
                    className="bg-green-600 text-white hover:bg-green-700"
                    disabilitata={["risolta", "chiusa"].includes(
                      pratica.stato_assistenza || ""
                    )}
                    motivoDisabilitata="Stato attuale"
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="operatore_non_assistenza"
                    label="Non è un’assistenza"
                    className="bg-slate-800 text-white hover:bg-slate-900"
                  />
                </div>
              ) : (
                <div>
                  {statoConfermaClienteVisuale === "in_attesa" && (
                    <div className="mb-4 rounded-xl border border-amber-300 bg-amber-50 p-4">
                      <div className="text-sm font-bold text-amber-950">
                        Dati non confermati dal cliente
                      </div>
                      <p className="mt-1 text-xs leading-5 text-amber-900">
                        Keplero ha raccolto dati sufficienti per la pratica, ma
                        non abbiamo ancora una conferma esplicita del cliente.
                        Lo stato commerciale non viene modificato da questo
                        avviso.
                      </p>
                    </div>
                  )}

                  {statoConfermaClienteVisuale === "confermato" && (
                    <div className="mb-4 rounded-xl border border-green-200 bg-green-50 p-4">
                      <div className="text-sm font-bold text-green-900">
                        Dati confermati dal cliente
                      </div>
                      <p className="mt-1 text-xs leading-5 text-green-800">
                        La conferma esplicita del cliente risulta registrata
                        {pratica.conferma_cliente_at
                          ? ` il ${formattaData(pratica.conferma_cliente_at)}`
                          : ""}.
                      </p>
                    </div>
                  )}

                  <div
                    className={`mb-4 rounded-xl border p-4 ${
                      codiciPronti
                        ? "border-green-200 bg-green-50"
                        : "border-orange-200 bg-orange-50"
                    }`}
                  >
                    <div
                      className={`text-sm font-bold ${
                        codiciPronti ? "text-green-800" : "text-orange-900"
                      }`}
                    >
                      {codiciPronti
                        ? "Codici verificati: pratica sbloccata"
                        : "Verifica codici necessaria"}
                    </div>

                    <div className="mt-1 text-xs leading-5 text-slate-600">
                      {codiciVisualizzati.length === 0
                        ? "Non è presente alcun codice identificativo."
                        : `${codiciConfermati} confermati · ${codiciScartati} scartati · ${codiciInAttesa} da verificare`}
                    </div>

                    {!codiciPronti && (
                      <div className="mt-2 text-xs font-semibold text-orange-800">
                        Dati verificati e Preventivo inviato restano bloccati.
                      </div>
                    )}
                  </div>

                  <div className="grid gap-3">
                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="commerciale_richiesta_verifica"
                    label="Richiesta verifiche / attesa risposta"
                    className="bg-yellow-100 text-yellow-900 hover:bg-yellow-200"
                    disabilitata={pratica.stato_commerciale === "richiesta_verifica"}
                    motivoDisabilitata="Stato attuale"
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="commerciale_dati_mancanti"
                    label="Dati mancanti"
                    className="bg-slate-200 text-slate-900 hover:bg-slate-300"
                    disabilitata={pratica.stato_completezza === "dati_mancanti"}
                    motivoDisabilitata="Stato attuale"
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="commerciale_dati_verificati"
                    label="Dati verificati → da preventivare"
                    className="bg-orange-100 text-orange-900 hover:bg-orange-200"
                    disabilitata={
                      pratica.stato_commerciale === "da_preventivare" ||
                      !codiciPronti
                    }
                    motivoDisabilitata={
                      pratica.stato_commerciale === "da_preventivare"
                        ? "Stato attuale"
                        : "Bloccato: verifica codici"
                    }
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="commerciale_preventivo_inviato"
                    label="Preventivo inviato"
                    className="bg-blue-600 text-white hover:bg-blue-700"
                    disabilitata={
                      pratica.stato_commerciale === "preventivo_inviato" ||
                      !codiciPronti
                    }
                    motivoDisabilitata={
                      pratica.stato_commerciale === "preventivo_inviato"
                        ? "Stato attuale"
                        : "Bloccato: verifica codici"
                    }
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="commerciale_ordine_acquisito"
                    label="Ordine acquisito"
                    className="bg-red-100 text-red-900 hover:bg-red-200"
                    disabilitata={
                      pratica.stato_commerciale !== "preventivo_inviato"
                    }
                    motivoDisabilitata={
                      pratica.stato_commerciale === "ordine_acquisito"
                        ? "Completato"
                        : "Bloccato: prima invia il preventivo"
                    }
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="commerciale_fatturata"
                    label="Fatturata"
                    className="bg-green-600 text-white hover:bg-green-700"
                    disabilitata={
                      pratica.stato_fatturazione === "fatturato" ||
                      pratica.stato_commerciale !== "ordine_acquisito"
                    }
                    motivoDisabilitata={
                      pratica.stato_fatturazione === "fatturato"
                        ? "Stato attuale"
                        : "Bloccato: prima acquisisci l’ordine"
                    }
                  />

                  <AzioneOperatore
                    praticaId={pratica.id}
                    azione="commerciale_rifiuta_lavorazione"
                    label="Rifiuta lavorazione"
                    className="bg-red-600 text-white hover:bg-red-700"
                    disabilitata={pratica.stato_commerciale === "rifiutato"}
                    motivoDisabilitata="Stato attuale"
                  />
                  </div>

                  <details className="mt-5 rounded-xl border border-slate-300 bg-slate-50 p-4">
                    <summary className="cursor-pointer select-none text-sm font-bold text-slate-800">
                      Correzione manuale stato operatore
                    </summary>

                    <p className="mt-3 text-xs leading-5 text-slate-600">
                      Usa questa sezione quando la pratica è già più avanti di
                      quanto risulta dalla classificazione automatica. Questi
                      comandi bypassano i blocchi sui codici e rendono
                      prevalente lo stato scelto dall’operatore.
                    </p>

                    <div className="mt-4 grid gap-3">
                      <CorrezioneStatoOperatore
                        praticaId={pratica.id}
                        stato="da_preventivare"
                        label="Imposta: Da preventivare"
                        className="bg-orange-100 text-orange-900 hover:bg-orange-200"
                        disabilitata={
                          pratica.stato_commerciale === "da_preventivare" &&
                          pratica.stato_fatturazione !== "fatturato"
                        }
                      />

                      <CorrezioneStatoOperatore
                        praticaId={pratica.id}
                        stato="preventivo_inviato"
                        label="Imposta: Preventivo inviato"
                        className="bg-blue-600 text-white hover:bg-blue-700"
                        disabilitata={
                          pratica.stato_commerciale === "preventivo_inviato" &&
                          pratica.stato_fatturazione !== "fatturato"
                        }
                      />

                      <CorrezioneStatoOperatore
                        praticaId={pratica.id}
                        stato="ordine_acquisito"
                        label="Imposta: Ordine acquisito / da fatturare"
                        className="bg-red-100 text-red-900 hover:bg-red-200"
                        disabilitata={
                          pratica.stato_commerciale === "ordine_acquisito" &&
                          pratica.stato_fatturazione === "da_fatturare"
                        }
                      />

                      <CorrezioneStatoOperatore
                        praticaId={pratica.id}
                        stato="fatturata"
                        label="Imposta: Fatturata"
                        className="bg-green-600 text-white hover:bg-green-700"
                        disabilitata={pratica.stato_fatturazione === "fatturato"}
                      />
                    </div>
                  </details>
                </div>
              )}
            </Card>

            <Card titolo="Logistica / ritiro">
              <div className="mb-4 rounded-xl border border-slate-200 bg-slate-50 p-4">
                <div className="text-xs font-bold uppercase tracking-wide text-slate-400">
                  Stato logistica
                </div>
                <div className="mt-1 text-sm font-bold text-slate-900">
                  {etichettaStato(pratica.stato_logistica || "non_applicabile")}
                </div>

                {pratica.ritiro_richiesto_at && (
                  <div className="mt-2 text-xs text-slate-500">
                    Richiesto: {formattaData(pratica.ritiro_richiesto_at)}
                  </div>
                )}

                {pratica.ritiro_programmato_at && (
                  <div className="mt-1 text-xs text-slate-500">
                    Programmato: {formattaData(pratica.ritiro_programmato_at)}
                  </div>
                )}
              </div>

              <div className="grid gap-3">
                <AzioneOperatore
                  praticaId={pratica.id}
                  azione="logistica_ritiro_richiesto"
                  label="Ritiro richiesto"
                  className="bg-blue-100 text-blue-900 hover:bg-blue-200"
                  disabilitata={[
                    "ritiro_richiesto",
                    "ritiro_programmato",
                    "ritirato",
                  ].includes(pratica.stato_logistica || "")}
                  motivoDisabilitata="Stato già avanzato"
                />

                <AzioneOperatore
                  praticaId={pratica.id}
                  azione="logistica_ritiro_programmato"
                  label="Ritiro programmato"
                  className="bg-amber-100 text-amber-900 hover:bg-amber-200"
                  disabilitata={pratica.stato_logistica !== "ritiro_richiesto"}
                  motivoDisabilitata={
                    pratica.stato_logistica === "ritiro_programmato"
                      ? "Stato attuale"
                      : "Prima segna ritiro richiesto"
                  }
                />

                <AzioneOperatore
                  praticaId={pratica.id}
                  azione="logistica_ritirato"
                  label="Ritirato"
                  className="bg-green-600 text-white hover:bg-green-700"
                  disabilitata={
                    pratica.stato_logistica === "ritirato" ||
                    !["ritiro_richiesto", "ritiro_programmato"].includes(
                      pratica.stato_logistica || ""
                    )
                  }
                  motivoDisabilitata={
                    pratica.stato_logistica === "ritirato"
                      ? "Stato attuale"
                      : "Prima richiedi o programma il ritiro"
                  }
                />

                <AzioneOperatore
                  praticaId={pratica.id}
                  azione="logistica_annulla_ritiro"
                  label="Annulla ritiro"
                  className="bg-slate-200 text-slate-900 hover:bg-slate-300"
                  disabilitata={
                    !["ritiro_richiesto", "ritiro_programmato"].includes(
                      pratica.stato_logistica || ""
                    )
                  }
                  motivoDisabilitata="Nessun ritiro attivo"
                />
              </div>
            </Card>

            <Card titolo="Storico operatore">
              {storicoOperatore.length ? (
                <div className="space-y-3">
                  {storicoOperatore.map((evento) => (
                    <div
                      key={evento.id}
                      className="rounded-xl border border-slate-200 bg-slate-50 p-4"
                    >
                      <div className="text-sm font-bold text-slate-900">
                        {etichettaAzione(evento.azione)}
                      </div>
                      <div className="mt-1 text-xs text-slate-500">
                        {formattaData(evento.created_at)}
                      </div>
                      {evento.nota && (
                        <div className="mt-2 text-sm leading-6 text-slate-700">
                          {evento.nota}
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              ) : (
                <p className="text-sm text-slate-500">
                  Nessuna azione manuale registrata.
                </p>
              )}
            </Card>

            <Card titolo="Stato pratica">
              <div className="space-y-4">
                <Campo label="Completezza" value={etichettaStato(pratica.stato_completezza)} />
                <Campo
                  label="Conferma cliente"
                  value={etichettaConfermaCliente(statoConfermaClienteVisuale)}
                />
                {pratica.conferma_cliente_at && (
                  <Campo
                    label="Confermata il"
                    value={formattaData(pratica.conferma_cliente_at)}
                  />
                )}
                <Campo label="Stato commerciale" value={etichettaStato(pratica.stato_commerciale)} />
                <Campo label="Fatturazione" value={etichettaStato(pratica.stato_fatturazione)} />
                <Campo label="Logistica" value={etichettaStato(pratica.stato_logistica)} />
                <Campo label="Follow-up" value={etichettaStato(pratica.stato_followup)} />
              </div>
            </Card>

            {pratica.tipo_flusso === "assistenza" && (
              <Card titolo="Assistenza / Post-vendita">
                <div className="space-y-4">
                  <Campo
                    label="Tipo assistenza"
                    value={titoloAssistenza(pratica.tipo_assistenza)}
                  />
                  <Campo
                    label="Stato assistenza"
                    value={etichettaStato(pratica.stato_assistenza)}
                  />
                  <Campo
                    label="Priorità"
                    value={etichettaStato(pratica.priorita_assistenza)}
                  />
                  <Campo
                    label="Aperta"
                    value={formattaData(pratica.assistenza_aperta_at)}
                  />
                </div>

                {pratica.nota_assistenza && (
                  <div className="mt-5 rounded-xl bg-purple-50 p-4 text-sm leading-6 text-purple-950">
                    {pratica.nota_assistenza}
                  </div>
                )}
              </Card>
            )}

            <Card titolo="Controllo operatore">
              <div className="space-y-4">
                <Campo
                  label="Fonte completezza"
                  value={etichettaStato(pratica.fonte_completezza)}
                />
                <Campo
                  label="Classificazione"
                  value={etichettaStato(pratica.fonte_classificazione)}
                />
                <Campo
                  label="Classificazione bloccata"
                  value={
                    pratica.blocco_classificazione_operatore ? "Sì" : "No"
                  }
                />
                <Campo
                  label="Ultimo messaggio cliente"
                  value={formattaData(pratica.ultimo_messaggio_cliente_at)}
                />
              </div>
            </Card>

            {pratica.nota_incompletezza && (
              <Card titolo="Dati mancanti / note">
                <p className="whitespace-pre-wrap text-sm leading-6 text-slate-800">
                  {pratica.nota_incompletezza}
                </p>
              </Card>
            )}

            <Card titolo="Origine e riferimenti">
              <div className="space-y-4">
                <Campo
                  label="Keplero conversation ID"
                  value={pratica.keplero_conversation_id}
                  mono
                />
                <Campo
                  label="Preventivo inviato"
                  value={formattaData(pratica.preventivo_inviato_at)}
                />
                <Campo
                  label="Ordine acquisito"
                  value={formattaData(pratica.ordine_acquisito_at)}
                />
                <Campo
                  label="Ritiro richiesto"
                  value={formattaData(pratica.ritiro_richiesto_at)}
                />
                <Campo
                  label="Ritiro programmato"
                  value={formattaData(pratica.ritiro_programmato_at)}
                />
                <Campo
                  label="Follow-up previsto"
                  value={formattaData(pratica.followup_previsto_at)}
                />
              </div>
            </Card>
          </aside>
        </div>
      </div>
    </main>
  );
}

function Card({
  titolo,
  children,
}: {
  titolo: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-2xl border border-slate-200 bg-white p-6 shadow-sm">
      <h2 className="mb-5 text-base font-bold text-slate-950">{titolo}</h2>
      {children}
    </section>
  );
}

function Campo({
  label,
  value,
  mono = false,
}: {
  label: string;
  value: unknown;
  mono?: boolean;
}) {
  return (
    <div>
      <div className="text-xs font-bold uppercase tracking-wide text-slate-400">
        {label}
      </div>
      <div
        className={`mt-1 break-words text-sm font-semibold text-slate-900 ${
          mono ? "font-mono" : ""
        }`}
      >
        {leggibile(value)}
      </div>
    </div>
  );
}



function VerificaDtcButton({
  praticaId,
  codice,
  esito,
  label,
  className,
  disabilitato = false,
}: {
  praticaId: string;
  codice: string;
  esito: "confermato" | "scartato";
  label: string;
  className: string;
  disabilitato?: boolean;
}) {
  return (
    <form action={verificaDtcOperatore}>
      <input type="hidden" name="pratica_id" value={praticaId} />
      <input type="hidden" name="codice" value={codice} />
      <input type="hidden" name="esito" value={esito} />

      <button
        type="submit"
        disabled={disabilitato}
        className={`rounded-lg px-3 py-2 text-xs font-bold transition ${
          disabilitato
            ? "cursor-not-allowed bg-slate-100 text-slate-400"
            : className
        }`}
      >
        {disabilitato ? "Stato attuale" : label}
      </button>
    </form>
  );
}

function VerificaCodiceButton({
  praticaId,
  codice,
  esito,
  label,
  className,
  disabilitato = false,
}: {
  praticaId: string;
  codice: string;
  esito: "confermato" | "scartato";
  label: string;
  className: string;
  disabilitato?: boolean;
}) {
  return (
    <form action={verificaCodiceOperatore}>
      <input type="hidden" name="pratica_id" value={praticaId} />
      <input type="hidden" name="codice" value={codice} />
      <input type="hidden" name="esito" value={esito} />

      <button
        type="submit"
        disabled={disabilitato}
        className={`rounded-lg px-3 py-2 text-xs font-bold transition ${
          disabilitato
            ? "cursor-not-allowed bg-slate-100 text-slate-400"
            : className
        }`}
      >
        {disabilitato ? "Stato attuale" : label}
      </button>
    </form>
  );
}

function CorrezioneStatoOperatore({
  praticaId,
  stato,
  label,
  className,
  disabilitata = false,
}: {
  praticaId: string;
  stato: "da_preventivare" | "preventivo_inviato" | "ordine_acquisito" | "fatturata";
  label: string;
  className: string;
  disabilitata?: boolean;
}) {
  return (
    <form action={correggiStatoCommercialeOperatore}>
      <input type="hidden" name="pratica_id" value={praticaId} />
      <input type="hidden" name="stato" value={stato} />

      <button
        type="submit"
        disabled={disabilitata}
        className={`w-full rounded-xl px-4 py-3 text-left text-sm font-bold transition ${
          disabilitata
            ? "cursor-not-allowed bg-slate-100 text-slate-400"
            : className
        }`}
      >
        {disabilitata ? `${label} · Stato attuale` : label}
      </button>
    </form>
  );
}

function AzioneOperatore({
  praticaId,
  azione,
  label,
  className,
  disabilitata = false,
  motivoDisabilitata = "Bloccato",
}: {
  praticaId: string;
  azione: string;
  label: string;
  className: string;
  disabilitata?: boolean;
  motivoDisabilitata?: string;
}) {
  return (
    <form action={applicaAzioneOperatore}>
      <input type="hidden" name="pratica_id" value={praticaId} />
      <input type="hidden" name="azione" value={azione} />

      <button
        type="submit"
        disabled={disabilitata}
        className={`w-full rounded-xl px-4 py-3 text-left text-sm font-bold transition ${
          disabilitata
            ? "cursor-not-allowed bg-slate-100 text-slate-400"
            : className
        }`}
      >
        {label}
        {disabilitata ? ` · ${motivoDisabilitata}` : ""}
      </button>
    </form>
  );
}
