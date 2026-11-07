"use client";

import { createContext, useContext, useEffect, useState, type ReactNode } from "react";
import type { ProssimaAzione, SezionePratica } from "../lib/oggi";

const SEZIONI = [
  ["dati", "Dati e diagnosi"], ["offerta", "Offerta e ordine"],
  ["logistica", "Logistica e assistenza"], ["amministrazione", "Amministrazione"],
  ["storico", "Documenti e storico"],
] as const;
type Vista = SezionePratica | "tutte";
const ContestoSezioni = createContext<Vista>("tutte");
function sezioneValida(value: string | null): value is Vista {
  return value === "tutte" || SEZIONI.some(([id]) => id === value);
}
export function SchedaPratica({ praticaId, iniziale = "dati", azione, protetta, children }: {
  praticaId: string; iniziale?: SezionePratica; azione: ProssimaAzione; protetta: boolean; children: ReactNode;
}) {
  const [sezione, setSezione] = useState<Vista>(iniziale);
  useEffect(() => {
    const aggiorna = () => {
      const hash = window.location.hash.replace(/^#sezione-/, "");
      if (sezioneValida(hash)) setSezione(hash);
    };
    aggiorna();
    window.addEventListener("hashchange", aggiorna);
    return () => window.removeEventListener("hashchange", aggiorna);
  }, [praticaId]);

  function apri(vista: Vista) {
    // Si cambia solo la vista: i form rimangono montati e i valori non salvati sono conservati.
    setSezione(vista);
    window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}#sezione-${vista}`);
  }
  return <ContestoSezioni.Provider value={sezione}>
    <div className="pratica-sezioni" data-sezione={sezione}>
      <section aria-label="Prossima azione" className="mb-5 flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-blue-200 bg-blue-50 p-5">
        <div className="max-w-3xl"><p className="text-xs font-bold uppercase tracking-wider text-blue-700">{azione.stato === "da_lavorare" ? "Prossima azione suggerita" : azione.stato === "in_attesa" ? "Pratica in attesa" : "Consultazione"}</p>
          <h2 className="mt-1 text-lg font-bold text-blue-950">{azione.titolo}</h2><p className="mt-1 text-sm leading-6 text-blue-900">{azione.motivo}</p>
          {protetta && <p className="mt-2 text-xs font-semibold text-amber-950">Sono presenti dati o classificazioni protetti dall’operatore. I blocchi restano attivi.</p>}
        </div>
        <button type="button" onClick={() => apri(azione.sezione)} className="min-h-11 rounded-lg bg-blue-800 px-4 py-2.5 text-sm font-bold text-white hover:bg-blue-900">Apri la sezione →</button>
      </section>
      <nav aria-label="Sezioni della pratica" className="mb-5 flex flex-wrap gap-2 rounded-2xl border border-slate-200 bg-white p-2">
        {SEZIONI.map(([id, titolo]) => <button key={id} type="button" aria-pressed={sezione === id} onClick={() => apri(id)}
          className={`min-h-11 flex-1 whitespace-nowrap rounded-xl px-4 py-3 text-sm font-semibold ${sezione === id ? "bg-blue-950 text-white" : "text-slate-600 hover:bg-slate-100"}`}>{titolo}</button>)}
        <button type="button" aria-pressed={sezione === "tutte"} onClick={() => apri("tutte")} className={`min-h-11 rounded-xl px-4 py-3 text-sm ${sezione === "tutte" ? "bg-slate-800 font-bold text-white" : "text-slate-500 hover:bg-slate-100"}`}>Vista completa</button>
      </nav>
      <p className="mb-4 text-xs text-slate-500">Cambiare sezione non salva né modifica la pratica. Le azioni restano manuali.</p>
      {children}
    </div>
  </ContestoSezioni.Provider>;
}

export function SezionePraticaVisibile({ sezioni, children }: { sezioni: SezionePratica[]; children: ReactNode }) {
  const selezionata = useContext(ContestoSezioni);
  return <div hidden={selezionata !== "tutte" && !sezioni.includes(selezionata)}>{children}</div>;
}

export function CardPratica({ titolo, children }: { titolo: string; children: ReactNode }) {
  const categorie: Record<string, SezionePratica[]> = {
    "Cliente e veicolo": ["dati"], "Problema / riepilogo operativo": ["dati"],
    "Codici identificativi": ["dati"], "DTC / codici guasto": ["dati"],
    "Allegati Keplero": ["dati", "storico"], "Conversazione Keplero": ["storico"],
    "Azioni operatore": ["dati", "offerta", "logistica", "amministrazione"],
    "Attività operative rilevate": ["logistica"], "Logistica / ritiro": ["logistica"],
    "Note interne operatore": ["dati", "offerta", "logistica", "amministrazione", "storico"],
    "Storico operatore": ["storico"], "Documenti amministrativi registrati": ["amministrazione", "storico"],
    "Cliente fiscale": ["amministrazione"], "Stato pratica": ["dati", "offerta"],
    "Assistenza / Post-vendita": ["logistica"], "Controllo operatore": ["storico"],
    "Dati mancanti / note": ["dati"], "Origine e riferimenti": ["storico"],
  };
  const visibili = categorie[titolo] || ["dati"];
  return <SezionePraticaVisibile sezioni={visibili}>
    {titolo === "Azioni operatore" ? <details className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <summary className="cursor-pointer text-base font-bold text-slate-950">Azioni e correzioni operatore</summary>
      <p className="mb-5 mt-2 text-xs leading-5 text-slate-500">Comandi manuali esistenti. Apri solo per effettuare l’azione desiderata.</p>{children}
    </details> : <section className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm sm:p-6"><h2 className="mb-5 text-base font-bold text-slate-950">{titolo}</h2>{children}</section>}
  </SezionePraticaVisibile>;
}
