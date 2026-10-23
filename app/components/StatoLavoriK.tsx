import Link from "next/link";
import { leggiStatoLavoriK } from "../lib/lavoriKepleroServer";

export async function StatoLavoriK() {
  const s = await leggiStatoLavoriK().catch(() => null);
  const fermo = s?.controllo.attivo && s.controllo_in_ritardo;
  return <section className="mb-6 rounded-2xl border border-blue-200 bg-white p-5">
    <div className="flex flex-wrap items-center justify-between gap-3"><h2 className="text-lg font-bold">Pratiche da completare o allineare</h2><Link href="/keplero/pratiche" className="rounded-lg bg-blue-900 px-4 py-2 text-sm font-bold text-white">Apri coda{s ? ` · ${s.lavori_aperti}` : ""}</Link></div>
    {s ? <><p className="mt-3 text-sm">Da lavorare: <strong>{s.lavori_aperti}</strong> · Prioritarie: <strong>{s.prioritari}</strong> · Da associare: {s.da_associare}</p>
      <p className="mt-2 text-sm"><Link className="font-bold text-blue-800 underline" href="/keplero/pratiche?attesa=1">In attesa del controllo automatico: {s.lavori_in_attesa_automazione ?? "conteggio non disponibile"}</Link> · Ingressi da elaborare: {s.ingressi_in_elaborazione}</p>
      {(!s.controllo.attivo || fermo || s.controllo.errore || s.errori > 0 || s.ingressi_in_ritardo > 0) && <p role="alert" className="mt-3 font-bold text-red-800">{!s.controllo.attivo ? "Riconciliazione sospesa." : fermo ? "Riconciliazione in ritardo o ferma." : "Sono presenti elaborazioni da recuperare."} Eventi in ritardo: {s.ingressi_in_ritardo} · Errori: {s.errori}.</p>}
      {s.originali_in_ritardo && <p role="alert" className="mt-3 font-bold text-red-800">Recupero delle chat originali sospeso, in ritardo o con errori: copertura da verificare.</p>}
      <p className="mt-2 text-xs text-slate-600">Ultimo controllo completato: {s.controllo.ultimo_successo_at ? new Date(s.controllo.ultimo_successo_at).toLocaleString("it-IT", { timeZone: "Europe/Rome" }) : "da completare"}. La copertura delle chat dipende anche dal recupero degli originali K.</p></> : <p role="alert" className="mt-3 font-bold text-red-800">Coda non disponibile: l’assenza di dati non conferma che tutte le pratiche siano allineate.</p>}
  </section>;
}
