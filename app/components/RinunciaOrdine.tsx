"use client";

import { useActionState } from "react";
import { gestisciRinunciaOrdine } from "../pratica/[id]/actions";

export function RinunciaOrdine({ praticaId, annullatoAt, acquisitoAt }: {
  praticaId: string;
  annullatoAt?: string | null;
  acquisitoAt?: string | null;
}) {
  const [esito, azione, inCorso] = useActionState(gestisciRinunciaOrdine, { messaggio: "" });
  return (
    <details className="mb-5 rounded-xl border border-slate-300 bg-white p-4">
      <summary className="cursor-pointer text-sm font-bold text-slate-900">
        {annullatoAt ? "Riapri la pratica" : "Il cliente ha annullato l’ordine"}
      </summary>
      <form action={azione} className="mt-3 grid max-w-xl gap-3">
        <p className="text-sm text-slate-700">
          {annullatoAt
            ? "Riapri la fase di preventivo. Per acquisire di nuovo l’ordine servirà una nuova conferma del cliente."
            : "La pratica uscirà dagli ordini da fatturare e da evadere. Il preventivo resterà nello storico."}
        </p>
        <input type="hidden" name="pratica_id" value={praticaId} />
        <input type="hidden" name="comando" value={annullatoAt ? "riapri" : "annulla"} />
        <input type="hidden" name="riferimento" value={annullatoAt || acquisitoAt || ""} />
        <label className="grid gap-1 text-sm text-slate-700">
          Nota per lo storico (facoltativa)
          <textarea name="nota" maxLength={2000} rows={2} className="rounded-lg border border-slate-300 p-2" />
        </label>
        <button disabled={inCorso} className="w-fit rounded-lg bg-slate-800 px-4 py-2 text-sm font-bold text-white disabled:opacity-50">
          {inCorso ? "Salvataggio…" : annullatoAt ? "Conferma riapertura" : "Conferma annullamento"}
        </button>
        {esito.messaggio && <p role="status" className="text-sm font-medium">{esito.messaggio}</p>}
      </form>
    </details>
  );
}
