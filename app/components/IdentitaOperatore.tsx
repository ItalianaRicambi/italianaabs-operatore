import {
  cambiaOperatore,
  selezionaOperatore,
} from "../actions-operatore";
import { OPERATORI, type Operatore } from "../operatore";

export function AccessoOperatore() {
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
          Seleziona l’operatore che sta iniziando la sessione. Tutte le modifiche
          verranno registrate nello storico con questa identificazione.
        </p>

        <form action={selezionaOperatore} className="mt-7 grid gap-3 sm:grid-cols-2">
          {OPERATORI.map((operatore) => (
            <button
              key={operatore}
              type="submit"
              name="operatore"
              value={operatore}
              className="rounded-2xl border border-blue-200 bg-blue-50 px-5 py-5 text-left text-base font-bold text-blue-950 transition hover:border-blue-400 hover:bg-blue-100"
            >
              {operatore}
            </button>
          ))}
        </form>

        <p className="mt-6 text-xs leading-5 text-slate-500">
          La scelta resta valida fino alla chiusura del browser oppure fino a
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

