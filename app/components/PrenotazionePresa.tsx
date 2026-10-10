"use client";

import { useActionState, useState } from "react";
import { importaPrenotazionePresa } from "../pratica/[id]/actions";
import { leggiPrenotazionePresa } from "../lib/prenotazioniPrese";

export function PrenotazionePresa({ praticaId, attivitaId, testoIniziale = "", riferimento = "", dataRitiro = "" }: {
  praticaId: string; attivitaId: string; testoIniziale?: string; riferimento?: string; dataRitiro?: string;
}) {
  const [testo, setTesto] = useState(testoIniziale);
  const [codice, setCodice] = useState(riferimento);
  const [data, setData] = useState(dataRitiro);
  const [lettura, setLettura] = useState("");
  const [state, action, pending] = useActionState(importaPrenotazionePresa, { ok: false, messaggio: "" });
  const input = "w-full rounded-lg border border-slate-300 bg-white p-2 text-sm";
  function leggi() {
    const dati = leggiPrenotazionePresa(testo);
    setCodice(dati.riferimento || ""); setData(dati.data_ritiro || "");
    setLettura(dati.errore || "Data e codice riconosciuti. Conferma la prenotazione effettuata.");
  }
  return <details className="mt-3 rounded-xl border border-blue-200 bg-blue-50 p-3" open={Boolean(testoIniziale)}>
    <summary className="cursor-pointer text-sm font-bold text-blue-900">Registra la presa dal messaggio o dalla conferma GLS</summary>
    <form action={action} className="mt-3 space-y-2">
      <input type="hidden" name="pratica_id" value={praticaId} />
      <input type="hidden" name="attivita_id" value={attivitaId} />
      <label className="block text-xs font-semibold">Testo della prenotazione
        <textarea className={input} name="testo" value={testo} onChange={e => setTesto(e.target.value)} maxLength={30000} required placeholder="Incolla il messaggio inviato al cliente o la conferma GLS" />
      </label>
      <button type="button" onClick={leggi} className="rounded-lg border border-blue-300 bg-white px-3 py-2 text-sm font-bold text-blue-900">Leggi data e codice</button>
      {lettura && <p className="text-xs text-blue-900" role="status">{lettura}</p>}
      <div className="grid grid-cols-2 gap-2">
        <label className="text-xs font-semibold">Codice completo<input className={input} name="riferimento" value={codice} onChange={e => setCodice(e.target.value)} required maxLength={80} placeholder="P3 9260993058" /></label>
        <label className="text-xs font-semibold">Data della presa<input className={input} type="date" name="data_ritiro" value={data} onChange={e => setData(e.target.value)} required /></label>
      </div>
      <label className="flex items-start gap-2 text-xs"><input className="mt-1" type="checkbox" name="verificata" required />Ho verificato che la presa sia stata prenotata con questi dati.</label>
      <p className="text-xs text-slate-600">Una risposta del cliente precompila i dati. La conferma registra la prenotazione; il pacco resta da ritirare.</p>
      <button disabled={pending} className="rounded-lg bg-blue-700 px-3 py-2 text-sm font-bold text-white disabled:opacity-50">{pending ? "Registrazione…" : "Conferma presa prenotata"}</button>
      {state.messaggio && <p role="status" className={`text-sm font-semibold ${state.ok ? "text-green-800" : "text-red-800"}`}>{state.messaggio}</p>}
    </form>
  </details>;
}
