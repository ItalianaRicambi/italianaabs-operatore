import Link from "next/link";
import { redirect } from "next/navigation";
import { getOperatoreAttivo } from "../../operatore";
import { BarraOperatore } from "../../components/IdentitaOperatore";
import { StatoLavoriK } from "../../components/StatoLavoriK";
import { leggiLavoriK, leggiFontiLavoroK } from "../../lib/lavoriKepleroServer";
import { prendiInCaricoLavoroK, verificaEsitoFonteK } from "./actions";
export const dynamic = "force-dynamic";
const dataIt = (s: string) => new Date(s).toLocaleString("it-IT", { timeZone: "Europe/Rome" });
const nomiCampi: Record<string, string> = { targa: "Targa", codice_o_immagine_componente: "Codici o foto del componente", dtc_con_spie_accese: "Codici guasto non comunicati", stato_spie: "Stato delle spie", descrizione_guasto: "Descrizione del guasto", diagnosi_discordante_da_verificare_operatore: "Diagnosi da verificare" };

export default async function PraticheK({ searchParams }: { searchParams: Promise<Record<string, string | string[] | undefined>> }) {
  const op = await getOperatoreAttivo(); if (!op) redirect("/");
  const q = await searchParams;
  const pagina = Math.max(1, Math.min(100000, Number.parseInt(String(q.pagina || "1"), 10) || 1));
  const pratica = typeof q.pratica === "string" && /^[a-f0-9-]{36}$/i.test(q.pratica) ? q.pratica : undefined;
  const sessione = !pratica && typeof q.sessione === "string" && /^[a-f0-9-]{36}$/i.test(q.sessione) ? q.sessione : undefined;
  const scheda = !pratica && !sessione && typeof q.scheda === "string" && /^(live|originale|documento|richiesta):.{1,190}$/.test(q.scheda) ? q.scheda : undefined;
  const dettaglio = !!(pratica || sessione || scheda);
  const filtro = { pratica, sessione, scheda };
  let lavori = null, fonti = null;
  try { [lavori, fonti] = await Promise.all([leggiLavoriK(dettaglio ? 1 : pagina, filtro), leggiFontiLavoroK(filtro, pagina)]); } catch {}
  const collegamentoPagina = (n: number) => { const x = new URLSearchParams({ pagina: String(n) }); if (pratica) x.set("pratica", pratica); if (sessione) x.set("sessione", sessione); if (scheda) x.set("scheda", scheda); return `/keplero/pratiche?${x}`; };
  const totale = dettaglio ? fonti?.totale : lavori?.totale;
  return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={op} /><div className="mx-auto max-w-6xl px-6 py-8">
    <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link><h1 className="my-5 text-3xl font-bold">Pratiche da completare o allineare</h1><StatoLavoriK />
    <p className="mb-5 rounded-lg border bg-blue-50 p-4">Ogni scheda raccoglie il lavoro ancora necessario sulla pratica. La presa in carico assegna un responsabile. La scheda si risolve quando gli esiti risultano verificati e le azioni necessarie sono completate.</p>
    {q.salvato === "1" && <p role="status" className="mb-4 rounded border bg-green-50 p-3">Verifica registrata. Le altre azioni ancora necessarie restano visibili.</p>}
    {dettaglio && <Link href="/keplero/pratiche" className="mb-4 inline-block font-bold text-blue-800 underline">Tutte le pratiche</Link>}
    {lavori === null ? <p role="alert" className="font-bold text-red-800">Impossibile leggere la coda. Aggiornare la pagina.</p> : <>
      <p className="mb-4">{dettaglio ? "Dettaglio della scheda" : `${lavori.totale ?? "Totale non disponibile"} schede aperte · Pagina ${pagina}`}</p>
      {lavori.righe.map(l => <article key={l.chiave} className={`mb-5 rounded-xl border bg-white p-5 ${l.priorita === 0 ? "border-red-400" : "border-slate-200"}`}>
        <h2 className="text-lg font-bold">{l.numero_pratica ? `ABS-${String(l.numero_pratica).padStart(6, "0")} · ${l.targa || "Targa da acquisire"} · ${l.nome_cliente || ""}` : "Richiesta da associare alla pratica"}</h2>
        <p className="mt-2 font-semibold">{l.priorita === 0 ? "Conferma o elaborazione bloccata: verifica prioritaria" : l.priorita === 1 ? "Eventi o documenti da verificare" : l.azione_preventivo || "Richiesta da completare"}</p>
        {l.verifica_tecnica_necessaria && <p className="mt-2 font-bold text-amber-900">Da preventivare · Verifica tecnica necessaria</p>}
        {!!l.dati_mancanti?.length && <p className="mt-2 text-sm">Dati da acquisire/verificare: {l.dati_mancanti.map(c => nomiCampi[c] || c).join(", ")}.</p>}
        <p className="mt-3 text-sm">Rilevata: {dataIt(l.prima_rilevazione_at)} · Ultimo controllo: {dataIt(l.ultimo_controllo_at)} · Eventi aperti: {l.fonti_aperte}<br />Responsabile: {l.responsabile || "Da assegnare"}</p>
        <div className="mt-4 flex flex-wrap gap-5">{l.pratica_id && <Link href={`/pratica/${l.pratica_id}`} className="font-bold text-blue-800 underline">Apri pratica</Link>}
          {l.sessione && <a href={`https://console.keplero.ai/dashboard/${l.assistente}/conversations?sessionId=${l.sessione}`} target="_blank" rel="noreferrer" className="font-bold text-blue-800 underline">Leggi chat originale</a>}
          <Link href={l.pratica_id ? `/keplero/pratiche?pratica=${l.pratica_id}` : l.sessione ? `/keplero/pratiche?sessione=${l.sessione}` : `/keplero/pratiche?scheda=${encodeURIComponent(l.chiave)}`} className="font-bold text-blue-800 underline">Esamina eventi e documenti</Link></div>
        <form action={prendiInCaricoLavoroK} className="mt-4"><input type="hidden" name="chiave" value={l.chiave} /><input type="hidden" name="versione" value={l.versione} /><button className="rounded-lg border px-3 py-2 font-bold">{l.responsabile ? "Assegna a me" : "Prendi in carico"}</button></form>
      </article>)}
      {!lavori.righe.length && <p className="mb-5">Nessuna scheda aperta nel filtro selezionato.</p>}
      {dettaglio && (fonti === null ? <p role="alert">Eventi non disponibili.</p> : <section><h2 className="my-5 text-xl font-bold">Eventi da verificare · {fonti.totale ?? "Totale non disponibile"}</h2>{fonti.righe.map(f => <article key={`${f.fonte}:${f.chiave}`} className="mb-4 rounded-xl border bg-white p-5">
        <p className="text-sm">{dataIt(f.data_fonte)} · {f.fonte === "originale" ? "Chat originale" : f.fonte === "documento" ? "Documento" : "Richiesta ricevuta"}</p><p className="my-3 font-semibold">{f.motivo}</p>
        {f.contenuto_richiesta && <div className="my-3 rounded bg-slate-50 p-3 text-sm">{["nome_cliente", "telefono", "targa", "ultimo_messaggio_cliente", "descrizione_guasto"].map(c => typeof f.contenuto_richiesta?.[c] === "string" ? <p key={c} className="whitespace-pre-wrap">{String(f.contenuto_richiesta[c])}</p> : null)}</div>}
        <form action={verificaEsitoFonteK}><input type="hidden" name="fonte" value={f.fonte} /><input type="hidden" name="chiave" value={f.chiave} /><input type="hidden" name="impronta" value={f.impronta} /><input type="hidden" name="pratica" value={pratica || ""} /><input type="hidden" name="sessione" value={sessione || ""} /><input type="hidden" name="scheda" value={scheda || ""} />
          <label className="block text-sm font-semibold">Esito della verifica e azione eseguita<textarea name="nota" minLength={10} maxLength={2000} required className="mt-2 block min-h-20 w-full rounded-lg border p-3 font-normal" /></label><p className="my-2 text-xs text-slate-600">Per aggiornare ordine, scelta, fatturazione o dati usa la scheda pratica; qui registra la verifica di questo evento.</p><button className="rounded-lg border px-3 py-2 font-bold">Registra verifica dell’evento</button></form>
      </article>)}</section>)}
      <nav className="mt-6 flex items-center gap-5">{pagina > 1 && <Link className="font-bold text-blue-800 underline" href={collegamentoPagina(pagina - 1)}>Precedente</Link>}<span>Pagina {pagina}</span>{(totale === null || (totale ?? 0) > pagina * 50) && <Link className="font-bold text-blue-800 underline" href={collegamentoPagina(pagina + 1)}>Successiva</Link>}</nav>
    </>}
  </div></main>;
}
