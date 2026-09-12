"use client";

import Link from "next/link";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type MouseEvent,
  type ReactNode,
} from "react";

/*
 * NAVIGAZIONE_PRATICHE_V1_20260911
 * Riceve soltanto id/codice delle righe GIA' filtrate e ordinate dal server.
 * Non legge Supabase, non modifica stati e non contiene chiavi API.
 * La sequenza resta quella dell'elenco di partenza anche dopo un cambio stato.
 * Tornando all'elenco si ricostruisce la sequenza dai risultati della Dashboard.
 */
type VoceElenco = { id: string; codice: string };
type Elenco = {
  versione: 1;
  chiave: string;
  filtro: string;
  etichetta: string;
  cerca: string;
  voci: VoceElenco[];
};
type ElencoSalvato = Elenco & { salvatoIl: number };
type Parametro = string | string[] | undefined;

const PREFISSO = "italianaabs:navigazione:v1:";
const DURATA = 12 * 60 * 60 * 1000;
const MASSIMO_ELENCHI = 20;
const MASSIMO_VOCI = 10000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Usata solo nel browser, anche quando sessionStorage non è disponibile.
const memoria = new Map<string, ElencoSalvato>();

function primo(value: Parametro): string {
  return (Array.isArray(value) ? value[0] : value) || "";
}

function oggetto(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object";
}

function elencoValido(value: unknown): value is ElencoSalvato {
  if (!oggetto(value)) return false;
  if (
    value.versione !== 1 ||
    typeof value.chiave !== "string" || !UUID.test(value.chiave) ||
    typeof value.filtro !== "string" || value.filtro.length > 100 ||
    typeof value.etichetta !== "string" || value.etichetta.length > 200 ||
    typeof value.cerca !== "string" || value.cerca.length > 10000 ||
    typeof value.salvatoIl !== "number" || !Number.isFinite(value.salvatoIl) ||
    !Array.isArray(value.voci) || value.voci.length > MASSIMO_VOCI
  ) return false;

  const ids = new Set<string>();
  for (const voce of value.voci) {
    if (
      !oggetto(voce) || typeof voce.id !== "string" || !UUID.test(voce.id) ||
      typeof voce.codice !== "string" || voce.codice.length > 100 ||
      ids.has(voce.id)
    ) return false;
    ids.add(voce.id);
  }
  return true;
}

function recente(elenco: ElencoSalvato): boolean {
  const eta = Date.now() - elenco.salvatoIl;
  return eta >= -60000 && eta < DURATA;
}

function memorizzaElenco(elenco: Elenco): void {
  if (typeof window === "undefined") return;
  const salvato: ElencoSalvato = { ...elenco, salvatoIl: Date.now() };
  if (!elencoValido(salvato)) return;

  memoria.delete(elenco.chiave);
  memoria.set(elenco.chiave, salvato);
  for (const [chiave, valore] of memoria) {
    if (!recente(valore)) memoria.delete(chiave);
  }
  while (memoria.size > MASSIMO_ELENCHI) {
    const chiave = memoria.keys().next().value;
    if (!chiave) break;
    memoria.delete(chiave);
  }

  try {
    const storage = window.sessionStorage;
    const precedenti: Array<{ chiave: string; data: number }> = [];
    // Si leggono/rimuovono SOLO le chiavi di questa funzionalità.
    for (let i = 0; i < storage.length; i++) {
      const chiave = storage.key(i);
      if (!chiave?.startsWith(PREFISSO)) continue;
      try {
        const value: unknown = JSON.parse(storage.getItem(chiave) || "null");
        precedenti.push({
          chiave,
          data: elencoValido(value) && recente(value) ? value.salvatoIl : 0,
        });
      } catch {
        precedenti.push({ chiave, data: 0 });
      }
    }
    const daTenere = precedenti
      .filter((item) => item.data > 0 && item.chiave !== PREFISSO + elenco.chiave)
      .sort((a, b) => b.data - a.data)
      .slice(0, MASSIMO_ELENCHI - 1);
    const chiavi = new Set(daTenere.map((item) => item.chiave));
    for (const item of precedenti) {
      if (item.chiave !== PREFISSO + elenco.chiave && !chiavi.has(item.chiave)) {
        storage.removeItem(item.chiave);
      }
    }
    storage.setItem(PREFISSO + elenco.chiave, JSON.stringify(salvato));
  } catch {
    // Quota/privacy: resta utilizzabile la copia in memoria nella navigazione SPA.
    // Mai impedire di aprire una pratica a causa dello storage del browser.
  }
}

function leggiElenco(chiave: string): ElencoSalvato | null {
  if (typeof window === "undefined" || !UUID.test(chiave)) return null;
  const inMemoria = memoria.get(chiave);
  if (inMemoria && recente(inMemoria)) return inMemoria;
  memoria.delete(chiave);
  try {
    const valore: unknown = JSON.parse(window.sessionStorage.getItem(PREFISSO + chiave) || "null");
    if (elencoValido(valore) && valore.chiave === chiave && recente(valore)) {
      memoria.set(chiave, valore);
      return valore;
    }
    window.sessionStorage.removeItem(PREFISSO + chiave);
  } catch {
    // Contesto assente/corrotto: frecce disabilitate, mai un elenco indovinato.
  }
  return null;
}

function queryElenco(filtro: string, cerca: string): URLSearchParams {
  const query = new URLSearchParams();
  if (filtro && filtro !== "tutte") query.set("filtro", filtro);
  if (cerca) query.set("cerca", cerca);
  return query;
}

function hrefElenco(filtro: string, cerca: string, id?: string): string {
  const query = queryElenco(filtro, cerca).toString();
  const ancora = id && UUID.test(id) ? `#pratica-${id}` : "";
  return `${query ? `/?${query}` : "/"}${ancora}`;
}

function hrefPratica(id: string, elenco: Elenco): string {
  const query = queryElenco(elenco.filtro, elenco.cerca);
  query.set("nav", elenco.chiave);
  // Sempre un percorso interno: né lo storage né la ricerca possono introdurre URL esterni.
  return `/pratica/${encodeURIComponent(id)}?${query.toString()}`;
}

const Contesto = createContext<{ elenco: Elenco; ricorda: () => void } | null>(null);

export function ContestoNavigazioneElenco({
  chiave, filtro, etichetta, cerca, voci, children,
}: {
  chiave: string;
  filtro: string;
  etichetta: string;
  cerca: string;
  voci: VoceElenco[];
  children: ReactNode;
}) {
  const elenco = useMemo<Elenco>(
    () => ({ versione: 1, chiave, filtro, etichetta, cerca, voci }),
    [chiave, filtro, etichetta, cerca, voci]
  );
  const ricorda = useCallback(() => memorizzaElenco(elenco), [elenco]);
  useEffect(() => { ricorda(); }, [ricorda]);
  const value = useMemo(() => ({ elenco, ricorda }), [elenco, ricorda]);
  return <Contesto.Provider value={value}>{children}</Contesto.Provider>;
}

export function ApriPraticaConContesto({
  praticaId, children, className,
}: {
  praticaId: string;
  children: ReactNode;
  className?: string;
}) {
  const contesto = useContext(Contesto);
  return (
    <Link
      href={contesto ? hrefPratica(praticaId, contesto.elenco) : `/pratica/${encodeURIComponent(praticaId)}`}
      className={className}
      prefetch={false}
      onClick={() => contesto?.ricorda()}
      onAuxClick={() => contesto?.ricorda()}
      onContextMenu={() => contesto?.ricorda()}
    >
      {children}
    </Link>
  );
}

function modificheNonSalvate(): boolean {
  // Solo campi editabili nelle form della pratica, mai hidden o azioni sui pulsanti.
  const campi = document.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>(
    'main form input:not([type="hidden"]):not([type="submit"]):not([type="button"]), main form textarea, main form select'
  );
  for (const campo of campi) {
    if (campo.disabled) continue;
    if (campo instanceof HTMLSelectElement) {
      const opzioni = Array.from(campo.options);
      const predefiniti = opzioni.filter((opzione) => opzione.defaultSelected).map((opzione) => opzione.value);
      const iniziali = predefiniti.length ? predefiniti : campo.multiple ? [] : opzioni.slice(0, 1).map((opzione) => opzione.value);
      const attuali = Array.from(campo.selectedOptions).map((opzione) => opzione.value);
      if (JSON.stringify(attuali) !== JSON.stringify(iniziali)) return true;
    } else if (campo instanceof HTMLInputElement && ["checkbox", "radio"].includes(campo.type)) {
      if (campo.checked !== campo.defaultChecked) return true;
    } else if (campo instanceof HTMLInputElement && campo.type === "file") {
      if (campo.files?.length) return true;
    } else if (campo.value !== campo.defaultValue) {
      return true;
    }
  }
  return false;
}

function confermaUscita(event: MouseEvent<HTMLAnchorElement>): void {
  // Una nuova scheda non fa perdere i campi nella scheda attuale.
  if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey || event.button !== 0) return;
  if (modificheNonSalvate() && !window.confirm(
    "Ci sono modifiche non salvate nella pratica. Vuoi cambiare pagina senza salvarle?"
  )) {
    event.preventDefault();
  }
}

export function NavigazionePratica({
  praticaId, nav, filtro, cerca, posizione = "alto",
}: {
  praticaId: string;
  nav?: Parametro;
  filtro?: Parametro;
  cerca?: Parametro;
  posizione?: "alto" | "basso";
}) {
  const chiave = primo(nav);
  const filtroUrl = primo(filtro) || "tutte";
  const cercaUrl = primo(cerca).trim();
  const [letto, setLetto] = useState<{
    chiave: string;
    elenco: ElencoSalvato | null;
  } | null>(null);

  useEffect(() => {
    setLetto({ chiave, elenco: leggiElenco(chiave) });
  }, [chiave]);

  const caricato = letto?.chiave === chiave;
  const salvato = caricato && letto ? letto.elenco : null;
  // Non usare un contesto di un'altra categoria/ricerca.
  const elenco = salvato && salvato.filtro === filtroUrl && salvato.cerca === cercaUrl ? salvato : null;
  const indice = elenco?.voci.findIndex((voce) => voce.id === praticaId) ?? -1;
  const precedente = elenco && indice > 0 ? elenco.voci[indice - 1] : null;
  const successiva = elenco && indice >= 0 ? elenco.voci[indice + 1] || null : null;
  const ritorno = hrefElenco(elenco?.filtro || filtroUrl, elenco?.cerca ?? cercaUrl, praticaId);
  const classeLink = "flex min-h-11 items-center justify-center rounded-lg border border-blue-200 bg-blue-50 px-4 py-2.5 text-sm font-bold text-blue-800 transition hover:bg-blue-100 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-blue-600";
  const classeDisabilitato = "min-h-11 cursor-not-allowed rounded-lg border border-slate-200 bg-slate-100 px-4 py-2.5 text-sm font-semibold text-slate-400";

  function naviga(event: MouseEvent<HTMLAnchorElement>): void {
    confermaUscita(event);
    if (!event.defaultPrevented && elenco) memorizzaElenco(elenco);
  }

  return (
    <nav
      aria-label={`Navigazione pratiche ${posizione === "alto" ? "inizio" : "fine"} pagina`}
      className={`${posizione === "alto" ? "mb-6" : "mt-6"} rounded-2xl border border-slate-200 bg-white p-4 shadow-sm`}
    >
      <div className="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
        <Link href={ritorno} prefetch={false} onClick={confermaUscita}
          className="inline-flex items-center self-start rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-semibold text-slate-700 transition hover:bg-slate-50">
          ← Torna all’elenco
        </Link>
        <div className="min-w-0 flex-1 lg:px-4" aria-live="polite">
          {elenco && indice >= 0 ? (
            <>
              <div className="text-xs font-bold uppercase tracking-wide text-slate-500">Elenco di partenza</div>
              <div className="mt-1 text-sm font-bold text-slate-900">
                {elenco.etichetta} · Pratica {indice + 1} di {elenco.voci.length}
              </div>
              {elenco.cerca && <div className="mt-1 break-words text-xs text-slate-600">Ricerca: “{elenco.cerca}”</div>}
            </>
          ) : (
            <div className="text-sm text-slate-600">
              {!caricato ? "Caricamento della navigazione…" : chiave
                ? "Elenco di partenza non disponibile in questa scheda. Torna all’elenco e riapri la pratica."
                : "Apri una pratica dalla Dashboard per scorrere lo stesso elenco con le frecce."}
            </div>
          )}
        </div>
        <div className="grid grid-cols-2 gap-2 lg:min-w-[310px]">
          {precedente && elenco ? (
            <Link href={hrefPratica(precedente.id, elenco)} prefetch={false} onClick={naviga}
              className={classeLink} title={`Apri ${precedente.codice}`} aria-label={`Pratica precedente: ${precedente.codice}`}>
              ← Precedente
            </Link>
          ) : <button type="button" disabled className={classeDisabilitato}>← Precedente</button>}
          {successiva && elenco ? (
            <Link href={hrefPratica(successiva.id, elenco)} prefetch={false} onClick={naviga}
              className={classeLink} title={`Apri ${successiva.codice}`} aria-label={`Pratica successiva: ${successiva.codice}`}>
              Successiva →
            </Link>
          ) : <button type="button" disabled className={classeDisabilitato}>Successiva →</button>}
        </div>
      </div>
      {elenco && indice >= 0 && (
        <p className="mt-3 text-xs leading-5 text-slate-500">
          Ordine dell’elenco aperto, mantenuto anche dopo un cambio di stato. Torna all’elenco per aggiornarlo.
        </p>
      )}
    </nav>
  );
}
