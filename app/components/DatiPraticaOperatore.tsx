"use client";

import { startTransition, useActionState, useState } from "react";
import { salvaDatiPraticaOperatore } from "../pratica/[id]/actions";
import { CAMPI_DATI_PRATICA, type DatiPraticaModificabili, type EsitoSalvataggioDati } from "../lib/salvataggioDatiPratica";

const campi = [
  ["targa", "Targa", "Es. DE66571"],
  ["marca_veicolo", "Marca", "Es. BMW"],
  ["modello_veicolo", "Modello", "Es. R1200 GS"],
  ["tipo_componente", "Componente", "Es. ABS"],
] as const;
const classeCampo = "w-full rounded-lg border border-slate-300 bg-white px-3 py-2.5 text-sm text-slate-900 outline-none transition focus:border-blue-500 focus:ring-2 focus:ring-blue-100";

export function DatiPraticaOperatore({ praticaId, iniziali }: {
  praticaId: string; iniziali: DatiPraticaModificabili;
}) {
  const [dati, setDati] = useState(iniziali);
  const [salvati, setSalvati] = useState(iniziali);
  const [esito, azione, pending] = useActionState(async (stato: EsitoSalvataggioDati, formData: FormData) => {
    let risultato: EsitoSalvataggioDati;
    try {
      risultato = await salvaDatiPraticaOperatore(stato, formData);
    } catch {
      return { ok: false, messaggio: "Connessione interrotta: salvataggio da verificare. Le modifiche restano nei campi; riprova prima di uscire." };
    }
    if (risultato.ok && risultato.dati) {
      setDati(risultato.dati);
      setSalvati(risultato.dati);
    }
    return risultato;
  }, { ok: false, messaggio: "" });
  const modificati = CAMPI_DATI_PRATICA.some(campo => dati[campo] !== salvati[campo]);

  return <form onSubmit={event => {
    event.preventDefault();
    if (pending) return;
    const formData = new FormData(event.currentTarget);
    // Invio esplicito: il reset automatico delle form React non deve riportare
    // il select alla prima opzione dopo un salvataggio già confermato.
    startTransition(() => azione(formData));
  }} data-monitoraggio-modifiche="gestito"
    data-modifiche-non-salvate={modificati || pending ? "true" : "false"} aria-busy={pending}>
    <input type="hidden" name="pratica_id" value={praticaId} />
    <div className="grid gap-3 xl:grid-cols-[140px_1fr_1fr_160px]">
      {campi.map(([nome, label, placeholder]) => <label key={nome} className="block text-xs font-bold uppercase tracking-wide text-slate-500">
        {label}<input type="text" name={nome} placeholder={placeholder} readOnly={pending}
          value={dati[nome]} onChange={event => setDati({ ...dati, [nome]: event.target.value })}
          className={`${classeCampo} mt-1 ${nome === "targa" ? "font-mono font-semibold" : "font-semibold"}`} />
      </label>)}
    </div>
    <div className="mt-3 grid gap-3 xl:grid-cols-[220px_1fr_auto] xl:items-end">
      <label className="block text-xs font-bold uppercase tracking-wide text-slate-500">Tipo guasto
        <select name="tipo_guasto" value={dati.tipo_guasto} disabled={pending}
          onChange={event => setDati({ ...dati, tipo_guasto: event.target.value })} className={`${classeCampo} mt-1 font-semibold`}>
          <option value="">Seleziona...</option>
          <option value="idraulico_meccanico">Idraulico / meccanico</option>
          <option value="elettrico_elettronico">Elettrico / elettronico</option>
          <option value="non_definito">Non definito / da verificare</option>
        </select>
      </label>
      <label className="block text-xs font-bold uppercase tracking-wide text-slate-500">Descrizione guasto
        <input type="text" name="descrizione_guasto" value={dati.descrizione_guasto} readOnly={pending}
          onChange={event => setDati({ ...dati, descrizione_guasto: event.target.value })}
          placeholder="Es. rimane frenata la ruota posteriore destra" className={`${classeCampo} mt-1 font-normal normal-case tracking-normal`} />
      </label>
      <button type="submit" disabled={pending}
        className="rounded-lg bg-blue-600 px-5 py-2.5 text-sm font-bold text-white transition hover:bg-blue-700 disabled:cursor-wait disabled:opacity-60">
        {pending ? "Salvataggio in corso…" : "Salva e conferma"}
      </button>
    </div>
    <div aria-live="polite" className="mt-3 text-sm font-semibold">
      {pending ? <p role="status" className="text-blue-800">Salvataggio in corso…</p>
        : esito.messaggio && (!esito.ok || !modificati)
          ? <p role={esito.ok ? "status" : "alert"} className={esito.ok ? "text-green-800" : "text-red-800"}>{esito.messaggio}</p>
          : modificati ? <p className="text-amber-800">Modifiche da salvare.</p> : null}
    </div>
  </form>;
}
