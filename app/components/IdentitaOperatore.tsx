"use client";

import { useActionState, useState } from "react";
import {
  cambiaOperatore,
  selezionaOperatore,
} from "../actions-operatore";

type Operatore =
  | "Operatore 1"
  | "Operatore 2"
  | "Operatore 3"
  | "Operatore 4";

const OPERATORI: Operatore[] = [
  "Operatore 1",
  "Operatore 2",
  "Operatore 3",
  "Operatore 4",
];

const STATO_INIZIALE = { errore: null as string | null };

export function AccessoOperatore() {
  const [operatoreSelezionato, setOperatoreSelezionato] =
    useState<Operatore>("Operatore 1");
  const [stato, azioneAccesso, caricamento] = useActionState(
    selezionaOperatore,
    STATO_INIZIALE
  );

  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-100 px-6 py-12">
      <section className="w-full max-w-xl rounded-3xl border border-slate-200 bg-white p-8 shadow-xl">
        <p className="text-sm font-bold uppercase tracking-[0.18em] text-blue-600">
          Italiana Ricambi / ItalianaABS
        </p>
        <h1 className="mt-3 text-3xl font-bold tracking-tight text-slate-950">
          Accesso Dashboard Operatore
        </h1>
        <p className="mt-3 text-sm leading-6 text-slate-600">
          Seleziona l’operatore e inserisci il relativo PIN personale. Tutte le
          modifiche saranno registrate nello storico con questa identificazione.
        </p>

        <form action={azioneAccesso} className="mt-7">
          <div className="grid gap-3 sm:grid-cols-2">
            {OPERATORI.map((operatore) => {
              const selezionato = operatoreSelezionato === operatore;

              return (
                <label
                  key={operatore}
                  className={`cursor-pointer rounded-2xl border px-5 py-5 text-left text-base font-bold transition ${
                    selezionato
                      ? "border-blue-600 bg-blue-600 text-white shadow-md"
                      : "border-blue-200 bg-blue-50 text-blue-950 hover:border-blue-400 hover:bg-blue-100"
                  }`}
                >
                  <input
                    type="radio"
                    name="operatore"
                    value={operatore}
                    checked={selezionato}
                    onChange={() => setOperatoreSelezionato(operatore)}
                    className="sr-only"
                  />
                  {operatore}
                </label>
              );
            })}
          </div>

          <label className="mt-6 block text-sm font-bold text-slate-800">
            PIN personale
            <input
              type="password"
              name="pin"
              inputMode="numeric"
              pattern="[0-9]*"
              minLength={6}
              maxLength={12}
              autoComplete="current-password"
              required
              autoFocus
              className="mt-2 w-full rounded-xl border border-slate-300 bg-white px-4 py-3 text-lg tracking-[0.25em] text-slate-950 outline-none transition focus:border-blue-500 focus:ring-4 focus:ring-blue-100"
              placeholder="Inserisci il PIN"
            />
          </label>

          {stato.errore ? (
            <p
              role="alert"
              aria-live="polite"
              className="mt-4 rounded-xl border border-red-200 bg-red-50 px-4 py-3 text-sm font-bold text-red-700"
            >
              {stato.errore}
            </p>
          ) : null}

          <button
            type="submit"
            disabled={caricamento}
            className="mt-5 w-full rounded-xl bg-blue-600 px-5 py-3 text-base font-bold text-white transition hover:bg-blue-700 disabled:cursor-wait disabled:opacity-60"
          >
            {caricamento ? "Accesso in corso…" : "Accedi alla Dashboard"}
          </button>
        </form>

        <p className="mt-6 text-xs leading-5 text-slate-500">
          La sessione resta valida fino alla chiusura del browser oppure fino a
          quando viene selezionato “Cambia operatore”.
        </p>
      </section>
    </main>
  );
}

export function BarraOperatore({ operatore }: { operatore: Operatore }) {
  return (
    <div className="border-b border-blue-200 bg-blue-50">
      <div className="mx-auto flex max-w-[1750px] items-center justify-between gap-4 px-6 py-3">
        <div className="text-sm text-blue-950">
          Operatore attivo: <strong>{operatore}</strong>
        </div>

        <form action={cambiaOperatore}>
          <button
            type="submit"
            className="rounded-lg border border-blue-300 bg-white px-3 py-2 text-xs font-bold text-blue-900 transition hover:bg-blue-100"
          >
            Cambia operatore
          </button>
        </form>
      </div>
    </div>
  );
}
