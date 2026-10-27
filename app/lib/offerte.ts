import { createHash } from "node:crypto";

import { SERVIZI, type Servizio } from "./serviziOfferta.ts";
export { SERVIZI, type Servizio } from "./serviziOfferta.ts";
export type OpzioneOfferta = {
  numero: number; numero_esplicito: boolean; servizio: Servizio; descrizione: string;
  importo: number; iva_inclusa: boolean | null; valuta: string;
  condizioni: string; reso_vecchio: boolean | null;
};
export type LetturaOfferta = { opzioni: OpzioneOfferta[]; impronta: string; testo: string; errore: string | null; validita_giorni: number | null };

export function servizioDaTesto(value: string): Servizio | null {
  const t = value.toUpperCase().replace(/\s+/g, " ");
  if (/\bPSMI\b|PROGRAMMA SCAMBIO MADE IN ITALY/.test(t)) return "PSMI";
  if (/\bPS\b|PROGRAMMA SCAMBIO/.test(t)) return "PS";
  // Una revisione completa non va trasformata in sola idraulica o elettronica.
  // Solo una voce commerciale: un costo di test che la cita non è un'offerta RC.
  if (/^(?:(?:OPZIONE|OFFERTA)\s+[1-8]\s*[-–:]?\s*)?(?:RC\b|REVISIONE COMPLETA\b)/.test(t.trim())) return "RC";
  if (/\bRI\b|(?:LAVORAZIONE|RIPARAZIONE|REVISIONE) (?:DELLA PARTE |DELLA SEZIONE )?IDRAULICA/.test(t)) return "RI";
  if (/\bRE\b|(?:LAVORAZIONE|RIPARAZIONE|REVISIONE) (?:DELLA PARTE |DELLA SEZIONE )?ELETTRONICA/.test(t)) return "RE";
  return null;
}

export function normalizzaOpzioni(value: unknown): OpzioneOfferta[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > 8) throw new Error("Da 1 a 8 alternative richieste");
  const numeri = new Set<number>();
  return value.map((raw) => {
    if (!raw || typeof raw !== "object") throw new Error("Alternativa non valida");
    const o = raw as Record<string, unknown>;
    const servizio = String(o.servizio || "").toUpperCase() as Servizio;
    const numero = Number(o.numero), importo = Number(o.importo);
    if (!(servizio in SERVIZI) || !Number.isInteger(numero) || numero < 1 || numero > 8 || numeri.has(numero)) throw new Error("Servizio o numero dell’alternativa non valido");
    if (!Number.isFinite(importo) || importo <= 0 || importo > 100000 || Math.abs(importo * 100 - Math.round(importo * 100)) > 0.000001) throw new Error("Importo non valido");
    if (o.valuta && o.valuta !== "EUR") throw new Error("Valuta non supportata");
    numeri.add(numero);
    return { numero, numero_esplicito: o.numero_esplicito !== false, servizio, importo, valuta: "EUR",
      descrizione: String(o.descrizione || SERVIZI[servizio]).slice(0, 500),
      iva_inclusa: typeof o.iva_inclusa === "boolean" ? o.iva_inclusa : null,
      condizioni: String(o.condizioni || "").slice(0, 6000),
      reso_vecchio: typeof o.reso_vecchio === "boolean" ? o.reso_vecchio : null };
  }).sort((a, b) => a.numero - b.numero);
}

/** Associa solo prezzi espliciti al servizio sulla stessa riga/voce commerciale.
 * La citazione di PS in una nota o il costo di un test non diventano alternative. */
export function leggiOffertaDaTesto(raw: string, targa: string): LetturaOfferta {
  const testo = raw.replace(/\r/g, "").replace(/[\t\u00a0]/g, " ").trim();
  const impronta = createHash("sha256").update(testo.replace(/\s+/g, " ")).digest("hex");
  const errore = (messaggio: string): LetturaOfferta => ({ opzioni: [], impronta, testo, errore: messaggio, validita_giorni: null });
  if (testo.length < 60) return errore("PDF privo di testo leggibile: verifica operatore richiesta");
  if (testo.length > 200000) return errore("Documento troppo lungo");
  const targhe = [...testo.matchAll(/\bTarga\s*:\s*([A-Z0-9 -]{4,14})/gi)].map(m => m[1].trim().toUpperCase().replace(/[^A-Z0-9]/g, ""));
  if (!targhe.length || targhe.some(t => t !== targa)) return errore("La targa nel PDF è assente o non coincide con la pratica");
  const compatto = testo.replace(/\s+/g, " ");
  const intestazioni = [...testo.matchAll(/\b(?:Opzione|Offerta)\s+(\d+)\s*[-–:]?\s*([^\n€]{5,130})/gi)];
  const ordinali = new Map<Servizio, number>();
  for (const m of intestazioni) {
    // Il servizio deve trovarsi nel titolo, prima della descrizione successiva.
    const servizio = servizioDaTesto(m[2].slice(0, 95));
    if (servizio) {
      if (ordinali.has(servizio) && ordinali.get(servizio) !== Number(m[1])) return errore("Numerazione delle alternative contraddittoria");
      ordinali.set(servizio, Number(m[1]));
    }
  }
  const opzioni: OpzioneOfferta[] = [];
  const righe = testo.split("\n");
  // Alcuni preventivi a soluzione unica dichiarano il servizio nel titolo e
  // riportano soltanto «Prezzo: € ...» nella sezione economica.
  // Un ritorno a capo tipografico non deve spezzare «Programma Scambio».
  // Si ricompone solo questa continuazione esatta, non il paragrafo seguente.
  const titoliTecnici = righe.flatMap((r, i) => /^\s*Offerta tecnica\b/i.test(r)
    ? [r + (/\bProgramma\s*$/i.test(r) && /^\s*Scambio(?: Made in Italy)?\s*$/i.test(righe[i + 1] || "") ? " " + righe[i + 1].trim() : "")] : [])
    .map(r => r.replace(/^\s*Offerta tecnica\s*(?:per\s+)?/i, "").trim());
  const serviziNelDocumento = new Set(righe.map(r => servizioDaTesto(r.trim())).filter(Boolean));
  const prezziGenerici = righe.filter(r => /^\s*Prezzo\s*:\s*(?:€|[\d.,]+\s*(?:€|euro))/i.test(r));
  const servizioTitolo = titoliTecnici.length === 1 ? servizioDaTesto(titoliTecnici[0]) : null;
  const titoloUnico = servizioTitolo && intestazioni.length === 0 && serviziNelDocumento.size <= 1
    && [...serviziNelDocumento].every(s => s === servizioTitolo) && prezziGenerici.length === 1 ? titoliTecnici[0] : null;
  // Il modello SBC descrive esplicitamente la fornitura europea con reso
  // obbligatorio, ma non usa la sigla PS nella voce economica.
  const fornituraSbc = titoliTecnici.length === 1 && /^complessivo SBC Mercedes-Benz\s*$/i.test(titoliTecnici[0])
    && intestazioni.length === 0 && serviziNelDocumento.size === 0
    && /fornitura di un dispositivo SBC revisionato.{0,80}magazzino centralizzato europeo/i.test(compatto)
    && /Il reso del vecchio complessivo SBC è obbligatorio/i.test(compatto);
  let prezzoSbc = false;
  let prezzoDaTitolo = false;
  for (let i = 0; i < righe.length; i++) {
    let riga = righe[i].trim();
    if (titoloUnico && /^Prezzo\s*:/i.test(riga)) {
      riga = titoloUnico + ": " + riga.replace(/^Prezzo\s*:\s*/i, "");
      prezzoDaTitolo = true;
    }
    // Consente titoli e importi su due righe, senza attraversare sezioni lunghe.
    if (!riga.includes("€") && servizioDaTesto(riga) && /^\s*(?:€|[0-9]+[,.][0-9]{2}\s*€)/.test(righe[i + 1] || "")) riga += " " + righe[++i].trim();
    const prezzi = [...riga.matchAll(/€\s*([\d.]+(?:,\d{2})?)|([\d.]+(?:,\d{2})?)\s*(?:€|euro)/gi)];
    const prezzo = prezzi[0];
    if (!prezzo) continue;
    let servizio = servizioDaTesto(riga.slice(0, prezzo.index));
    if (!servizio && fornituraSbc && /^Complessivo SBC revisionato con 1 anno di garanzia\s*:\s*$/i.test(riga.slice(0, prezzo.index).trim())) {
      servizio = "PS";
      prezzoSbc = true;
    }
    if (!servizio) continue;
    if (prezzi.length !== 1) return errore("Più importi nella stessa voce: verifica richiesta");
    const valore = prezzo[1] || prezzo[2];
    // Alcuni modelli usano il punto sia per le migliaia sia per i centesimi.
    // Accetta solo gruppi completi di tre cifre seguiti da due decimali.
    const importo = Number(valore.includes(",") ? valore.replace(/\./g, "").replace(",", ".")
      : /^\d{1,3}(?:\.\d{3})+\.\d{2}$/.test(valore)
        ? valore.slice(0, -3).replace(/\./g, "") + valore.slice(-3) : valore);
    const gia = opzioni.find(o => o.servizio === servizio);
    if (gia) {
      if (gia.importo !== importo) return errore("Più prezzi per lo stesso servizio: verifica richiesta");
      if ((gia.iva_inclusa === true && /(?:oltre|esclusa)\s*IVA|IVA\s*esclusa/i.test(riga)) ||
        (gia.iva_inclusa === false && /IVA\s*(?:inclusa|compresa)/i.test(riga))) return errore("Indicazioni IVA contraddittorie: verifica richiesta");
      continue;
    }
    const numeroDiretto = /\b(?:Offerta|Opzione)\s+(\d+)/i.exec(riga);
    const numero = numeroDiretto ? Number(numeroDiretto[1]) : ordinali.get(servizio) ?? opzioni.length + 1;
    const posizioneTitolo = compatto.search(new RegExp("(?:Opzione|Offerta)\\s+" + numero + "\\b", "i"));
    const sezione = posizioneTitolo >= 0 ? compatto.slice(posizioneTitolo).split(/\b(?:Opzione|Offerta)\s+\d+\b/i).slice(1, 2).join("") : riga;
    opzioni.push({ numero, numero_esplicito: !!numeroDiretto || ordinali.has(servizio), servizio,
      descrizione: servizio === "RC" ? riga.slice(0, prezzo.index).replace(/^\s*(?:Offerta|Opzione)\s+[1-8]\s*[-–:]?\s*/i, "").replace(/[:\s]+$/, "") : SERVIZI[servizio], importo,
      iva_inclusa: /IVA\s*(?:inclusa|compresa)/i.test(riga) ? true : /(?:oltre|esclusa)\s*IVA|IVA\s*esclusa/i.test(riga) ? false : null,
      valuta: "EUR", condizioni: (sezione || riga).slice(0, 6000),
      reso_vecchio: servizio === "RI" || servizio === "RE" || servizio === "RC" ? false : /(?:reso|rientro|restitu).{0,80}vecchio|vecchio.{0,80}(?:reso|rientro|restitu)/i.test(sezione) ? true : null });
  }
  if (!opzioni.length) return errore("Alternative e prezzi non identificati nel PDF");
  if (opzioni.length === 1 && (opzioni[0].servizio === "RC" || prezzoDaTitolo || prezzoSbc)) {
    // Le limitazioni alla garanzia possono seguire il prezzo, anche in altre pagine.
    const inizio = testo.search(/Importo (?:dell[’']intervento|della fornitura)/i);
    const condizioni = inizio >= 0 ? testo.slice(inizio) : testo;
    if (condizioni.length > 6000) return errore("Condizioni dell’offerta da verificare nel PDF");
    opzioni[0].condizioni = condizioni;
    if (prezzoSbc) {
      opzioni[0].descrizione = "Complessivo SBC revisionato con 1 anno di garanzia";
      opzioni[0].reso_vecchio = true;
      opzioni[0].condizioni = "Reso del vecchio complessivo SBC obbligatorio dopo la sostituzione.\n" + condizioni;
    } else if (prezzoDaTitolo && /restituzione della ECU originale|restituzione della ECU originale completa/i.test(compatto)) {
      opzioni[0].reso_vecchio = true;
      opzioni[0].condizioni = "Restituzione della ECU originale completa e corrispondente obbligatoria; condizioni diverse da concordare prima dell’ordine.\n" + condizioni;
    }
    if (opzioni[0].condizioni.length > 6000) return errore("Condizioni dell’offerta da verificare nel PDF");
  }
  if ([...ordinali.keys()].some(s => !opzioni.some(o => o.servizio === s))) return errore("Manca il prezzo di una delle alternative proposte");
  try {
    const validita = /Validit[àa]\s*(?:offerta)?\s*:\s*(\d+)\s*giorni/i.exec(testo);
    return { opzioni: normalizzaOpzioni(opzioni), impronta, testo, errore: null, validita_giorni: validita ? Number(validita[1]) : null };
  } catch (e) { return errore(e instanceof Error ? e.message : "Alternative incoerenti"); }
}

export async function leggiOffertaDaPdf(bytes: Uint8Array, targa: string) {
  if (bytes.length > 3 * 1024 * 1024 || Buffer.from(bytes.subarray(0, 5)).toString() !== "%PDF-") throw new Error("PDF non valido o superiore a 3 MB");
  const { getDocumentProxy } = await import("unpdf");
  const pdf = await getDocumentProxy(bytes);
  try {
    if (pdf.numPages > 30) throw new Error("Il PDF supera 30 pagine");
    const pagine: string[] = [];
    for (let n = 1; n <= pdf.numPages; n++) {
      const pagina = await pdf.getPage(n);
      const contenuto = await pagina.getTextContent();
      pagine.push(contenuto.items.map(item => "str" in item ? item.str + (item.hasEOL ? "\n" : " ") : "").join(""));
      pagina.cleanup();
    }
    return leggiOffertaDaTesto(pagine.join("\n"), targa);
  } finally { await pdf.cleanup(); }
}
