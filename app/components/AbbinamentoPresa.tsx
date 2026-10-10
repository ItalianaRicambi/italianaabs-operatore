"use client";

import { useActionState } from "react";
import { confermaAbbinamentoPresa } from "../pratica/[id]/actions";

export function AbbinamentoPresa({ ricevutaId, ritiri }: { ricevutaId: string; ritiri: { id: string; label: string }[] }) {
  const [state, action, pending] = useActionState(confermaAbbinamentoPresa, { ok: false, messaggio: "" });
  return <form action={action} className="mt-3 space-y-2">
    <input type="hidden" name="ricevuta_id" value={ricevutaId} />
    <label className="block text-xs font-semibold">Ritiro verificato
      <select name="attivita_id" required defaultValue="" className="mt-1 w-full rounded-lg border border-slate-300 bg-white p-2 text-sm">
        <option value="" disabled>Seleziona dopo aver verificato destinatario e pratica</option>
        {ritiri.map(a => <option key={a.id} value={a.id}>{a.label}</option>)}
      </select>
    </label>
    <label className="flex items-start gap-2 text-xs"><input type="checkbox" name="verificata" required />Ho verificato che la conferma GLS riguardi questo ritiro e questi dati.</label>
    <button disabled={pending} className="rounded-lg bg-blue-700 px-3 py-2 text-sm font-bold text-white disabled:opacity-50">{pending ? "Registrazione…" : "Conferma abbinamento e prenotazione"}</button>
    {state.messaggio && <p role="status" className={`text-sm ${state.ok ? "text-green-800" : "text-red-800"}`}>{state.messaggio}</p>}
  </form>;
}
