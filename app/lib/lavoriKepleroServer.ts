import "server-only";
import { connessioneGlsDb } from "./glsServer";
import { rpcOriginaliK } from "./originaliKepleroServer";

export type StatoLavoriK = {
  controllo: { attivo: boolean; ultimo_tentativo_at: string | null; ultimo_successo_at: string | null; errore: string | null };
  controllo_in_ritardo: boolean; originali_in_ritardo: boolean;
  lavori_aperti: number; prioritari: number; da_associare: number;
  lavori_in_attesa_automazione?: number; lavori_totali?: number;
  ingressi_in_elaborazione: number; ingressi_in_ritardo: number; errori: number;
};
export type LavoroK = {
  chiave: string; pratica_id: string | null; sessione: string | null; stato: string;
  priorita: number; responsabile: string | null; scadenza_at: string;
  prima_rilevazione_at: string; ultimo_controllo_at: string; versione: number;
  numero_pratica: number | null; nome_cliente: string | null; targa: string | null;
  assistente: string; verifica_tecnica_necessaria: boolean; azione_preventivo: string | null;
  dati_mancanti: string[] | null; fonti_aperte: number;
  attesa_automazione: boolean;
};
export type FonteLavoroK = {
  fonte: string; chiave: string; stato: string; codice: string; motivo: string;
  data_fonte: string; impronta: string; contenuto_richiesta: Record<string, unknown> | null;
};
export const leggiStatoLavoriK = () => rpcOriginaliK<StatoLavoriK>("stato_esiti_commerciali_k");

export async function leggiLavoriK(pagina: number, filtro: { pratica?: string; sessione?: string; scheda?: string; attesa?: boolean } = {}) {
  const { url, headers } = connessioneGlsDb();
  const query = new URLSearchParams({ select: "*", stato: "neq.risolta", order: "priorita.asc,prima_rilevazione_at.asc,chiave.asc", limit: "50", offset: String((pagina - 1) * 50) });
  if (filtro.scheda) query.set("chiave", `eq.${filtro.scheda}`);
  else if (filtro.pratica) query.set("pratica_id", `eq.${filtro.pratica}`);
  else if (filtro.sessione) { query.set("sessione", `eq.${filtro.sessione}`); query.set("pratica_id", "is.null"); }
  else query.set("attesa_automazione", `eq.${filtro.attesa === true}`);
  const r = await fetch(`${url}/rest/v1/keplero_lavori_pratiche_elenco?${query}`, { headers: { ...headers, Prefer: "count=exact" }, cache: "no-store", signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error("Coda pratiche non disponibile");
  const totale = Number(r.headers.get("content-range")?.split("/")[1]);
  return { righe: await r.json() as LavoroK[], totale: Number.isFinite(totale) ? totale : null };
}

export async function leggiFontiLavoroK(filtro: { pratica?: string; sessione?: string; scheda?: string }, pagina: number) {
  const { url, headers } = connessioneGlsDb();
  const query = new URLSearchParams({ select: "fonte,chiave,stato,codice,motivo,data_fonte,impronta,contenuto_richiesta", stato: "in.(ricevuto,in_attesa,da_verificare)", order: "data_fonte.desc,fonte.asc,chiave.asc", limit: "50", offset: String((pagina - 1) * 50) });
  if (filtro.pratica) query.set("pratica_id", `eq.${filtro.pratica}`);
  else if (filtro.sessione) { query.set("sessione", `eq.${filtro.sessione}`); query.set("pratica_id", "is.null"); }
  else if (filtro.scheda) {
    const separatore = filtro.scheda.indexOf(":");
    const fonte = filtro.scheda.slice(0, separatore);
    if (!["live", "originale", "documento", "richiesta"].includes(fonte)) return { righe: [] as FonteLavoroK[], totale: 0 };
    query.set("fonte", `eq.${fonte}`); query.set("chiave", `eq.${filtro.scheda.slice(separatore + 1)}`); query.set("pratica_id", "is.null"); query.set("sessione", "is.null");
  }
  else return { righe: [] as FonteLavoroK[], totale: 0 };
  const r = await fetch(`${url}/rest/v1/keplero_esiti_fonti?${query}`, { headers: { ...headers, Prefer: "count=exact" }, cache: "no-store", signal: AbortSignal.timeout(15000) });
  if (!r.ok) throw new Error("Prove non disponibili");
  const totale = Number(r.headers.get("content-range")?.split("/")[1]);
  return { righe: await r.json() as FonteLavoroK[], totale: Number.isFinite(totale) ? totale : null };
}
