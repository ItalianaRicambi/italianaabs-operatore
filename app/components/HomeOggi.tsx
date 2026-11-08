import Link from "next/link";
import { randomUUID } from "node:crypto";
import type { ReactNode } from "react";
import type { Operatore } from "../operatore";
import { BarraOperatore } from "./IdentitaOperatore";
import { ApriPraticaConContesto, ContestoNavigazioneElenco } from "./NavigazionePratiche";
import { durataLavorativa, prossimaAzione, type PraticaOggi } from "../lib/oggi";

type Props = {
  operatore: Operatore;
  pratiche: PraticaOggi[];
  righe: PraticaOggi[];
  filtro: string;
  etichetta: string;
  cerca: string;
  pagina: number;
  giornoRoma: string;
  errore: string | null;
  controllo: { fermo: boolean; ultimo: string | null; aperte: number };
  email: { da_classificare: number; errori: number; allegati_da_verificare: number } | null;
  controlli: ReactNode;
};
const AREE = [
  ["oggi", "Oggi", "01"], ["area_pratiche", "Pratiche", "02"],
  ["area_logistica", "Logistica", "03"], ["area_assistenza", "Assistenza", "04"],
  ["area_amministrazione", "Amministrazione", "05"],
] as const;
const FILTRI_DETTAGLIO = [
  ["tutte", "Tutte le pratiche"], ["da_preventivare", "Da preventivare"],
  ["verifica_tecnica_preventivo", "Verifica tecnica"], ["da_verificare", "Dati da verificare"],
  ["dati_mancanti", "Dati mancanti"], ["richieste_verifiche", "Verifiche richieste al cliente"],
  ["preventivi_in_attesa", "Preventivi in attesa"], ["scelte_da_chiarire", "Scelte da chiarire"],
  ["offerte_da_verificare", "Offerte da verificare"], ["ordini_confermati", "Ordini confermati"],
  ["ordini_da_completare", "Ordini da completare"], ["da_fatturare", "Da fatturare"],
  ["ritiri_lavorazione", "Ritiri lavorazione"], ["ritiri_programma_scambio", "Rientri scambio"],
  ["prese_prenotate", "Prese prenotate"], ["ritiri_da_classificare", "Ritiri da classificare"],
  ["richiamate_post_preventivo", "Richiamate post-preventivo"], ["richiamate_post_vendita", "Richiamate post-vendita"],
  ["richiamate_da_classificare", "Richiamate da classificare"], ["garanzie_urgenti", "Rientri assistenza aperti"],
  ["assistenza_da_evadere", "Assistenze da evadere"], ["assistenza_aperta", "Assistenze aperte"],
  ["assistenza_prioritaria", "Assistenze urgenti"], ["admin_cliente_riconosciuto", "Clienti riconosciuti"],
  ["admin_dati_mancanti", "Dati amministrativi mancanti"], ["admin_corrispondenza_ambigua", "Anagrafiche da chiarire"],
  ["admin_pronto_fatturazione", "Pronti per fatturazione"], ["admin_richieste_da_inviare", "Richieste dati da inviare"],
  ["admin_attesa_dati_cliente", "Dati fiscali richiesti"], ["preventivi_mese_corrente", "Preventivi del mese"],
  ["fatture_mese_corrente", "Fatture del mese"], ["preventivi_mese_precedente", "Archivio preventivi mese precedente"],
  ["fatture_mese_precedente", "Archivio fatture mese precedente"],
] as const;
function href(filtro: string, cerca = "", pagina = 1) {
  const query = new URLSearchParams({ filtro });
  if (cerca) query.set("cerca", cerca);
  if (pagina > 1) query.set("pagina", String(pagina));
  return `/?${query}`;
}
function dataIt(data: string | null | undefined) {
  if (!data || !Number.isFinite(Date.parse(data))) return "Non disponibile";
  return new Intl.DateTimeFormat("it-IT", { timeZone: "Europe/Rome", dateStyle: "short", timeStyle: "short" }).format(new Date(data));
}

export function HomeOggi({ operatore, pratiche, righe, filtro, etichetta, cerca, pagina: richiestaPagina, giornoRoma, errore, controllo, email, controlli }: Props) {
  const azioni = new Map(pratiche.map(p => [p.id, prossimaAzione(p, giornoRoma)]));
  const elenco = [...righe].sort((a, b) => {
    const aa = azioni.get(a.id)!, ab = azioni.get(b.id)!;
    const ordine = { da_lavorare: 0, in_attesa: 1, conclusa: 2 };
    return Number(ab.urgente) - Number(aa.urgente) || ordine[aa.stato] - ordine[ab.stato];
  });
  const perPagina = 5;
  const pagine = Math.max(1, Math.ceil(elenco.length / perPagina));
  const pagina = Math.min(Math.max(1, richiestaPagina), pagine);
  const visibili = elenco.slice((pagina - 1) * perPagina, pagina * perPagina);
  const valori = [...azioni.values()];
  const contatori = [
    { filtro: "oggi", titolo: "Da lavorare", n: valori.filter(a => a.stato === "da_lavorare").length, descrizione: "Richiedono un’azione dell’operatore" },
    { filtro: "oggi_urgenti", titolo: "Urgenti", n: valori.filter(a => a.urgente).length, descrizione: "Già comprese nelle pratiche da lavorare" },
    { filtro: "oggi_attesa", titolo: "In attesa", n: valori.filter(a => a.stato === "in_attesa").length, descrizione: "Cliente, dati o ritiro prenotato" },
    { filtro: "oggi_concluse", titolo: "Concluse", n: valori.filter(a => a.stato === "conclusa").length, descrizione: "Consultabili, fuori dalla coda di lavoro" },
  ];
  const centroControlli = filtro === "controlli";
  const titolo = centroControlli ? "Centro controlli" : filtro.startsWith("oggi") ? "Oggi" : etichetta;
  const chiave = randomUUID();
  const classica = `/?vista=classica${cerca ? `&cerca=${encodeURIComponent(cerca)}` : ""}`;
  return (
    <ContestoNavigazioneElenco chiave={chiave} filtro={filtro} etichetta={etichetta} cerca={cerca}
      ritorno={href(filtro, cerca, pagina)} righePerPagina={perPagina}
      voci={elenco.map(p => ({ id: p.id, codice: p.codice_pratica || p.id }))}>
      <main className="min-h-screen bg-slate-50 text-slate-900">
        <BarraOperatore operatore={operatore} />
        <div className="mx-auto grid max-w-[1600px] lg:grid-cols-[210px_minmax(0,1fr)]">
          <aside className="border-b border-slate-200 bg-white p-4 lg:min-h-[calc(100vh-72px)] lg:border-r lg:p-6">
            <Link href="/" className="block text-lg font-black tracking-tight text-blue-950">Italiana<span className="text-blue-600">ABS</span></Link>
            <p className="mt-1 text-xs font-medium text-slate-500">Area operatore</p>
            <nav aria-label="Aree di lavoro" className="mt-5 flex flex-wrap gap-1 lg:flex-col lg:gap-2">
              {AREE.map(([id, label, numero]) => {
                const attiva = id === "oggi" ? filtro.startsWith("oggi") : filtro === id;
                return <Link key={id} href={href(id)} prefetch={false} aria-current={attiva ? "page" : undefined}
                  className={`flex min-h-11 items-center gap-3 rounded-xl px-3 py-3 text-sm font-semibold transition ${attiva ? "bg-blue-950 text-white" : "text-slate-600 hover:bg-slate-100"}`}>
                  <span aria-hidden="true" className={`text-[10px] ${attiva ? "text-blue-200" : "text-slate-400"}`}>{numero}</span>{label}
                </Link>;
              })}
            </nav>
            <Link href="/fatture-in-cloud" prefetch={false} className="mt-2 block rounded-xl px-3 py-3 text-sm font-semibold text-blue-800 hover:bg-blue-50">Documenti Fatture in Cloud</Link>
            <div className="mt-5 border-t border-slate-200 pt-4 lg:mt-8">
              <Link href={href("controlli")} prefetch={false} aria-current={centroControlli ? "page" : undefined}
                className={`flex min-h-11 items-center justify-between gap-2 rounded-xl px-3 py-2 text-sm font-semibold ${centroControlli ? "bg-blue-100 text-blue-950" : "text-slate-600 hover:bg-slate-100"}`}>
                Centro controlli <span className={`rounded-full px-2 py-0.5 text-xs ${controllo.fermo ? "bg-red-100 text-red-800" : "bg-amber-100 text-amber-900"}`}>{controllo.fermo ? "!" : controllo.aperte}</span>
              </Link>
              <Link href={classica} prefetch={false} className="mt-3 block px-3 text-xs text-slate-500 underline underline-offset-4">Vista classica</Link>
            </div>
          </aside>
          <div className="min-w-0 p-4 sm:p-6 lg:p-8">
            <header className="mb-6 flex flex-wrap items-start justify-between gap-4">
              <div><p className="text-xs font-bold uppercase tracking-[0.15em] text-slate-500">Dashboard operatore</p>
                <h1 className="mt-2 text-3xl font-bold tracking-tight text-slate-950">{titolo}</h1>
                <p className="mt-2 max-w-2xl text-sm leading-6 text-slate-600">{centroControlli ? "Stato delle integrazioni, anomalie e registri originali." : "Una pratica, una prossima azione. Le attività aperte includono anche i giorni precedenti."}</p>
              </div>
              <Link href={href(filtro, cerca, pagina)} prefetch={false} className="rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-semibold hover:bg-slate-100">Aggiorna elenco</Link>
            </header>
            {errore && <p role="alert" className="mb-4 rounded-xl border border-red-300 bg-red-50 p-4 text-sm font-semibold text-red-900">Dati parziali o non disponibili: {errore}. I conteggi non attestano l’assenza di attività.</p>}
            <div className={`mb-6 flex flex-wrap items-center justify-between gap-3 rounded-xl border px-4 py-3 text-sm ${controllo.fermo ? "border-red-300 bg-red-50 text-red-950" : "border-slate-200 bg-white text-slate-700"}`} role={controllo.fermo ? "alert" : undefined}>
              <p><strong>{controllo.fermo ? "Controllo K fermo o in errore" : "Controllo K"}</strong><span className="ml-2">Ultima esecuzione: {dataIt(controllo.ultimo)} · {controllo.aperte} segnalazioni aperte</span></p>
              <Link href={href("controlli")} prefetch={false} className="font-bold underline underline-offset-4">Verifica copertura e anomalie →</Link>
            </div>
            {centroControlli ? controlli : <>
              <div className="mb-6 grid grid-cols-2 gap-3 xl:grid-cols-4">
                {contatori.map(c => <Link key={c.filtro} href={href(c.filtro)} prefetch={false} aria-current={filtro === c.filtro ? "page" : undefined}
                  className={`rounded-2xl border bg-white p-4 transition hover:border-blue-500 sm:p-5 ${filtro === c.filtro ? "border-blue-700 ring-1 ring-blue-700" : "border-slate-200"}`}>
                  <p className={`text-sm font-semibold ${c.filtro === "oggi_urgenti" ? "text-red-700" : "text-slate-600"}`}>{c.titolo}</p>
                  <p className="my-2 text-3xl font-bold tabular-nums text-slate-950">{errore ? "—" : c.n}</p>
                  <p className="text-xs leading-5 text-slate-500">{c.descrizione}</p>
                </Link>)}
              </div>
              <section aria-label="Elenco delle pratiche" className="overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm">
                <div className="border-b border-slate-200 p-4 sm:p-5">
                  <div className="flex flex-wrap items-center justify-between gap-2"><h2 className="font-bold text-slate-950">{etichetta}</h2><span className="text-sm text-slate-500">{elenco.length} pratiche{errore ? " lette · elenco parziale" : ""}</span></div>
                  <form method="GET" className="mt-4 flex flex-col gap-3 xl:flex-row">
                    <div className="min-w-0 flex-1"><label htmlFor="oggi-cerca" className="mb-1 block text-xs font-semibold text-slate-600">Cerca nella vista selezionata</label>
                      <input id="oggi-cerca" name="cerca" defaultValue={cerca} placeholder="Targa, pratica, cliente o telefono" className="min-h-11 w-full rounded-lg border border-slate-300 px-3 text-sm outline-blue-600" /></div>
                    <div><label htmlFor="oggi-filtro" className="mb-1 block text-xs font-semibold text-slate-600">Vista / stato</label>
                      <select id="oggi-filtro" name="filtro" defaultValue={filtro} className="min-h-11 w-full rounded-lg border border-slate-300 bg-white px-3 text-sm xl:w-64">
                        <optgroup label="Lavoro dell’operatore">{contatori.map(c => <option key={c.filtro} value={c.filtro}>{c.titolo}</option>)}{AREE.filter(a => a[0] !== "oggi").map(([id, label]) => <option key={id} value={id}>{label}</option>)}</optgroup>
                        <optgroup label="Filtri di dettaglio">{FILTRI_DETTAGLIO.map(([id, label]) => <option key={id} value={id}>{label}</option>)}</optgroup>
                      </select></div>
                    <button className="min-h-11 self-end rounded-lg bg-blue-700 px-5 py-2.5 text-sm font-bold text-white hover:bg-blue-800">Cerca / filtra</button>
                  </form>
                  {cerca && <div className="mt-3 flex flex-wrap gap-4 text-sm"><span>Ricerca: <strong>{cerca}</strong></span><Link href={href(filtro)} className="text-blue-700 underline">Azzera ricerca</Link><Link href={href("tutte", cerca)} className="text-blue-700 underline">Cerca in tutte le pratiche</Link></div>}
                </div>
                <div className="hidden grid-cols-[1.1fr_1fr_1.6fr_130px] gap-5 border-b border-slate-100 bg-slate-50 px-5 py-3 text-xs font-bold uppercase tracking-wider text-slate-500 xl:grid" aria-hidden="true"><span>Pratica / cliente</span><span>Veicolo</span><span>Prossima azione</span><span>Apri scheda</span></div>
                {visibili.map(p => {
                  const a = azioni.get(p.id)!;
                  const durata = durataLavorativa(p);
                  const protetta = Boolean(p.blocco_operatore || p.blocco_classificazione_operatore || p.campi_bloccati_operatore?.length);
                  return <article key={p.id} id={`pratica-${p.id}`} className="grid scroll-mt-5 gap-3 border-b border-slate-100 p-4 last:border-0 sm:p-5 xl:grid-cols-[1.1fr_1fr_1.6fr_130px] xl:items-center xl:gap-5">
                    <div className="min-w-0"><p className="font-bold text-blue-950">{p.codice_pratica || p.id}</p><p className="mt-1 break-words text-sm text-slate-600">{p.nome_cliente || "Cliente da identificare"}</p><p className="mt-2 text-xs text-slate-500">{p.coda || p.stato_commerciale || "Stato da verificare"}</p></div>
                    <div className="min-w-0"><p className="font-mono text-base font-bold text-slate-950">{p.targa || "Targa mancante"}</p><p className="mt-1 break-words text-sm text-slate-600">{[p.marca_veicolo, p.modello_veicolo].filter(Boolean).join(" ") || "Veicolo da completare"}</p><p className="mt-1 text-xs text-slate-500">{p.tipo_componente || "Componente da identificare"}</p></div>
                    <div className="min-w-0"><div className="flex flex-wrap items-center gap-2"><p className="text-sm font-bold text-slate-950">{a.titolo}</p>{a.urgente && <span className="rounded-full bg-red-100 px-2 py-1 text-[10px] font-bold text-red-800">URGENTE</span>}</div><p className="mt-1 text-xs leading-5 text-slate-600">{a.motivo}</p><div className="mt-2 flex flex-wrap gap-2 text-[11px]">{durata && <span className={`rounded-md px-2 py-1 ${a.urgente ? "bg-red-50 text-red-800" : "bg-slate-100 text-slate-600"}`}>{durata}</span>}{protetta && <span className="rounded-md bg-amber-50 px-2 py-1 text-amber-900">Dati protetti dall’operatore</span>}</div></div>
                    <ApriPraticaConContesto praticaId={p.id} sezione={a.sezione} className="inline-flex min-h-11 items-center justify-center rounded-lg border border-blue-200 bg-blue-50 px-4 py-2 text-sm font-bold text-blue-800 hover:bg-blue-100">Apri pratica →</ApriPraticaConContesto>
                  </article>;
                })}
                {!visibili.length && <div className="px-5 py-12 text-center"><p className="font-semibold text-slate-800">{errore ? "Impossibile confermare il contenuto della coda." : "Nessuna pratica in questa vista."}</p><p className="mt-2 text-sm text-slate-500">{cerca ? "Prova un’altra ricerca o cerca in tutte le pratiche." : "Le altre attività restano nelle rispettive aree e nella vista classica."}</p></div>}
                <div className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-200 bg-slate-50 px-5 py-4 text-sm"><span className="text-slate-600">{elenco.length ? `${(pagina - 1) * perPagina + 1}–${Math.min(pagina * perPagina, elenco.length)} di ${elenco.length}` : "0 risultati"} · 5 pratiche alla volta</span><nav aria-label="Pagine dell’elenco" className="flex items-center gap-3">{pagina > 1 && <Link href={href(filtro, cerca, pagina - 1)} prefetch={false} className="rounded-lg border border-slate-300 bg-white px-3 py-2 font-semibold">← Precedenti</Link>}<span>{pagina} / {pagine}</span>{pagina < pagine && <Link href={href(filtro, cerca, pagina + 1)} prefetch={false} className="rounded-lg border border-slate-300 bg-white px-3 py-2 font-semibold">Successive →</Link>}</nav></div>
              </section>
              <section aria-label="Registri e richieste" className="mt-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
                <Link href="/email" prefetch={false} className="rounded-xl border border-slate-200 bg-white p-4"><p className="text-sm font-bold text-blue-900">Richieste email →</p><p className="mt-1 text-xs leading-5 text-slate-600">{email ? `${email.da_classificare} da classificare · ${email.allegati_da_verificare} allegati da verificare · ${email.errori} errori` : "Registro non disponibile: verificare"}</p></Link>
                <Link href="/preventivi" prefetch={false} className="rounded-xl border border-slate-200 bg-white p-4 text-sm font-bold text-blue-900">Acquisizione preventivi →<span className="mt-1 block text-xs font-normal text-slate-600">Documenti e invii da verificare</span></Link>
                <Link href="/gls" prefetch={false} className="rounded-xl border border-slate-200 bg-white p-4 text-sm font-bold text-blue-900">Prese GLS →<span className="mt-1 block text-xs font-normal text-slate-600">Esiti e motivazioni registrati</span></Link>
                <Link href="/mbe" prefetch={false} className="rounded-xl border border-slate-200 bg-white p-4 text-sm font-bold text-blue-900">Spedizioni MBE →<span className="mt-1 block text-xs font-normal text-slate-600">Tracking e abbinamenti</span></Link>
              </section>
              <p className="mt-5 text-xs leading-5 text-slate-500">La prossima azione è un’indicazione di lavoro: non modifica stati e non invia messaggi. Copertura email e Keplero parziale: l’assenza di avvisi non dimostra l’acquisizione di tutte le conversazioni.</p>
            </>}
          </div>
        </div>
      </main>
    </ContestoNavigazioneElenco>
  );
}
