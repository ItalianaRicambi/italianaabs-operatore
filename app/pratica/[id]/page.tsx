import Link from "next/link";
import { notFound } from "next/navigation";

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
  descrizione_guasto?: string | null;
  stato_completezza?: string | null;
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

  const [codici, allegati] = await Promise.all([
    selectSupabase<Codice[]>(
      `codici_identificativi?pratica_id=eq.${encodeURIComponent(id)}&select=*`
    ),
    selectSupabase<Allegato[]>(
      `allegati?pratica_id=eq.${encodeURIComponent(id)}&select=*`
    ),
  ]);

  return {
    pratica: pratiche[0],
    codici,
    allegati,
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
  const { pratica, codici, allegati } = await getPratica(id);

  const rawCodes = rawArray<RawCode>(
    pratica.dati_raw,
    "codici_identificativi_estratti"
  );
  const rawDtc = rawArray<string>(pratica.dati_raw, "dtc_estratti");
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

  const codiciVisualizzati =
    codici.length > 0
      ? codici.map((item) => ({
          codice: item.codice || "—",
          tipo: item.tipo_codice || "Identificativo",
          fonte: item.fonte || "database",
          verificato: Boolean(item.verificato_operatore),
          note: item.note || null,
        }))
      : rawCodes.map((item) => ({
          codice: item.codice || "—",
          tipo: "Identificativo",
          fonte:
            item.fonte === "cliente"
              ? "Cliente"
              : "Estrazione automatica dalla chat",
          verificato: Boolean(item.verificato),
          note: null,
        }));

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
              <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
                <Campo label="Cliente" value={pratica.nome_cliente} />
                <Campo label="Telefono" value={pratica.telefono} />
                <Campo label="Targa" value={pratica.targa} mono />
                <Campo label="Marca" value={pratica.marca_veicolo} />
                <Campo label="Modello" value={pratica.modello_veicolo} />
                <Campo label="Componente" value={pratica.tipo_componente} />
              </div>
            </Card>

            <Card titolo="Problema / riepilogo operativo">
              <p className="whitespace-pre-wrap text-sm leading-6 text-slate-800">
                {riepilogoOperativo ||
                  pratica.descrizione_guasto ||
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
              {codiciVisualizzati.length ? (
                <div className="overflow-x-auto">
                  <table className="w-full text-left text-sm">
                    <thead className="border-b border-slate-200 text-xs uppercase tracking-wide text-slate-500">
                      <tr>
                        <th className="py-3 pr-4">Tipo</th>
                        <th className="py-3 pr-4">Codice</th>
                        <th className="py-3 pr-4">Fonte</th>
                        <th className="py-3">Verifica</th>
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
                            {codice.fonte}
                          </td>
                          <td className="py-3">
                            {codice.verificato ? (
                              <span className="font-bold text-green-700">
                                Verificato
                              </span>
                            ) : (
                              <span className="font-bold text-orange-700">
                                Da verificare
                              </span>
                            )}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              ) : (
                <p className="text-sm text-slate-500">
                  Nessun codice identificativo estratto automaticamente.
                </p>
              )}
            </Card>

            <Card titolo="DTC / codici guasto">
              {rawDtc.length ? (
                <div className="flex flex-wrap gap-2">
                  {rawDtc.map((dtc) => (
                    <span
                      key={dtc}
                      className="rounded-lg border border-red-200 bg-red-50 px-3 py-2 font-mono text-sm font-bold text-red-800"
                    >
                      {dtc}
                    </span>
                  ))}
                </div>
              ) : (
                <p className="text-sm text-slate-500">
                  Nessun DTC estratto dalla conversazione.
                </p>
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
            <Card titolo="Stato pratica">
              <div className="space-y-4">
                <Campo label="Completezza" value={pratica.stato_completezza} />
                <Campo label="Stato commerciale" value={pratica.stato_commerciale} />
                <Campo label="Fatturazione" value={pratica.stato_fatturazione} />
                <Campo label="Follow-up" value={pratica.stato_followup} />
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
                    value={pratica.stato_assistenza}
                  />
                  <Campo
                    label="Priorità"
                    value={pratica.priorita_assistenza}
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
                  label="Classificazione"
                  value={pratica.fonte_classificazione}
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
