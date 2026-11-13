import { prontaPerFatturazione, fatturazioneSospesa } from "./fatturazione.ts";
import { sceltaClienteDaChiarire } from "./flussiOperativi.ts";
import type { MetadatiGls } from "./esitiGls.ts";

// Proiezione di sola lettura: non modifica le code, gli stati o le priorità salvate.
export type AreaOperativa = "pratiche" | "logistica" | "assistenza" | "amministrazione";
export type SezionePratica = "dati" | "offerta" | "logistica" | "amministrazione" | "storico";
export type StatoLavoro = "da_lavorare" | "in_attesa" | "conclusa";
export type PraticaOggi = {
  id: string;
  codice_pratica?: string;
  created_at?: string | null;
  nome_cliente?: string | null;
  telefono?: string | null;
  targa?: string | null;
  marca_veicolo?: string | null;
  modello_veicolo?: string | null;
  tipo_componente?: string | null;
  coda?: string;
  priorita?: number;
  tipo_flusso?: string | null;
  stato_commerciale?: string | null;
  stato_fatturazione?: string | null;
  stato_completezza?: string | null;
  stato_amministrativo?: string | null;
  stato_richiesta_amministrativa?: string | null;
  cliente_id?: string | null;
  dati_raw?: Record<string, unknown> | null;
  blocco_operatore?: boolean | null;
  blocco_classificazione_operatore?: boolean | null;
  campi_bloccati_operatore?: string[] | null;
  stato_assistenza?: string | null;
  priorita_assistenza?: string | null;
  verifica_tecnica_necessaria?: boolean;
  offerta_da_verificare?: boolean;
  minuti_lavorativi_preventivo?: number | null;
  minuti_lavorativi_verifica?: number | null;
  da_preventivare_at?: string | null;
  da_verificare_at?: string | null;
  scelta_cliente?: { stato: string; offerta_successiva: boolean; prezzo_da_verificare: boolean } | null;
  assistenze_rientro?: { stato: string; priorita: string; chiusa_at?: string | null }[];
  attivita_operative?: {
    tipo: string; stato: string; priorita: string; data_ritiro_prevista?: string | null;
    metadati?: MetadatiGls;
  }[];
};
export type ProssimaAzione = {
  titolo: string;
  motivo: string;
  area: AreaOperativa;
  sezione: SezionePratica;
  stato: StatoLavoro;
  urgente: boolean;
};
function azione(titolo: string, motivo: string, area: AreaOperativa, sezione: SezionePratica,
  stato: StatoLavoro = "da_lavorare", urgente = false): ProssimaAzione {
  return { titolo, motivo, area, sezione, stato, urgente: urgente && stato === "da_lavorare" };
}
function conclusa(p: PraticaOggi) {
  return p.tipo_flusso === "assistenza"
    ? ["risolta", "chiusa"].includes(p.stato_assistenza || "")
    : p.stato_fatturazione === "fatturato" || ["chiuso", "rifiutato"].includes(p.stato_commerciale || "");
}
type AttivitaOggi = NonNullable<PraticaOggi["attivita_operative"]>[number];
function azioneAttivita(operativa: AttivitaOggi, giornoRoma: string): ProssimaAzione {
  if (operativa.tipo === "followup_dati_preventivo" || operativa.tipo === "followup_dati_fatturazione")
    return azione("Verificare i dati ancora mancanti", "Nessuna risposta al promemoria da almeno 48 ore. Valutare la pratica; nessun secondo sollecito automatico.", operativa.tipo === "followup_dati_fatturazione" ? "amministrazione" : "pratiche", operativa.tipo === "followup_dati_fatturazione" ? "amministrazione" : "logistica");
  const ritiro = operativa.tipo.startsWith("ritiro_");
  const area = ritiro ? "logistica" : "pratiche";
  if (operativa.stato === "da_collegare") return azione("Verificare il collegamento", "Attività non collegata in modo univoco alla pratica di origine.", area, "logistica", "da_lavorare", operativa.priorita === "urgente");
  if (ritiro) {
    const esito = operativa.metadati?.gls?.stato;
    const scaduta = operativa.stato === "programmata" && Boolean(operativa.data_ritiro_prevista && operativa.data_ritiro_prevista < giornoRoma);
    if (["non_effettuata", "da_verificare", "annullata"].includes(esito || "") || (scaduta && esito !== "effettuata"))
      return azione("Verificare l’esito del ritiro", "Presa da verificare: non dedurre il ritiro dalla sola prenotazione.", "logistica", "logistica", "da_lavorare", operativa.priorita === "urgente");
    if (esito === "effettuata") return azione("Attendere la ricezione", "Ritiro registrato; la ricezione del dispositivo è un passaggio distinto.", "logistica", "logistica", "in_attesa");
    if (operativa.stato === "programmata") return azione("Attendere il ritiro prenotato", "Verificare l’esito nella sezione Logistica dopo la presa.", "logistica", "logistica", "in_attesa");
    return azione("Organizzare il ritiro", "Richiesta aperta: verificare tipo di ritiro e pratica di origine.", "logistica", "logistica", "da_lavorare", operativa.priorita === "urgente");
  }
  return azione("Gestire la richiamata", "Richiesta di contatto registrata; nessun messaggio viene inviato automaticamente.", "pratiche", "logistica", operativa.stato === "programmata" ? "in_attesa" : "da_lavorare", operativa.priorita === "urgente");
}
export function prossimaAzione(p: PraticaOggi, giornoRoma: string): ProssimaAzione {
  const aperte: ProssimaAzione[] = [];
  for (const rientro of p.assistenze_rientro || []) {
    if (rientro.chiusa_at || rientro.stato === "chiusa") continue;
    const attesa = ["ritiro_prenotato", "esito_comunicato"].includes(rientro.stato);
    aperte.push(azione(attesa ? "Attendere il rientro / riscontro" : "Gestire il rientro in assistenza",
      "Rientro aperto: verificare origine, avanzamento ed esito tecnico.", "assistenza", "logistica",
      attesa ? "in_attesa" : "da_lavorare", rientro.priorita === "urgente"));
  }
  // Una fattura non chiude un'attività. Una prenotazione non nasconde altre azioni aperte.
  for (const operativa of p.attivita_operative || []) {
    if (!["da_gestire", "da_collegare", "programmata"].includes(operativa.stato)) continue;
    const suggerita = azioneAttivita(operativa, giornoRoma);
    aperte.push(["chiuso", "rifiutato"].includes(p.stato_commerciale || "") && suggerita.stato === "da_lavorare"
      ? { ...suggerita, titolo: "Verificare l’attività rimasta aperta", motivo: "Pratica chiusa o rifiutata: rispettare la decisione dell’operatore prima di proseguire." }
      : suggerita);
  }
  aperte.push(azioneStato(p));
  const ordine = { da_lavorare: 0, in_attesa: 1, conclusa: 2 };
  return aperte.sort((a, b) => ordine[a.stato] - ordine[b.stato] || Number(b.urgente) - Number(a.urgente))[0];
}
function azioneStato(p: PraticaOggi): ProssimaAzione {
  if (conclusa(p)) return azione("Consultare la pratica", "Fase commerciale o assistenza conclusa; storico sempre disponibile.", p.tipo_flusso === "assistenza" ? "assistenza" : "pratiche", "storico", "conclusa");
  if (p.tipo_flusso === "assistenza") {
    const attesa = ["attesa_cliente", "attesa_rientro"].includes(p.stato_assistenza || "");
    return azione(attesa ? "Attendere cliente / rientro" : "Gestire l’assistenza", "Seguire lo stato di assistenza registrato dall’operatore.", "assistenza", "logistica", attesa ? "in_attesa" : "da_lavorare", p.priorita_assistenza === "urgente");
  }
  if (sceltaClienteDaChiarire({ ...p, tipo_flusso: p.tipo_flusso || "commerciale", stato_commerciale: p.stato_commerciale || "", stato_fatturazione: p.stato_fatturazione || "" }))
    return azione("Chiarire la scelta del cliente", "Scelta, versione dell’offerta o prezzo da verificare prima di procedere.", "pratiche", "offerta");
  if (p.offerta_da_verificare) return azione("Verificare l’offerta", "L’ultima offerta presenta elementi da controllare.", "pratiche", "offerta");
  if (p.stato_commerciale === "ordine_acquisito" || p.stato_fatturazione === "da_fatturare") {
    if (prontaPerFatturazione(p)) return azione("Preparare la fatturazione", "Ordine acquisito, cliente collegato e dati fiscali pronti.", "amministrazione", "amministrazione");
    if (fatturazioneSospesa(p)) return p.stato_richiesta_amministrativa === "inviata"
      ? azione("Attendere i dati fiscali", "Dati già richiesti al cliente. La sospensione resta attiva fino alla verifica e riabilitazione dell’operatore.", "amministrazione", "amministrazione", "in_attesa")
      : azione("Fatturazione sospesa", "In attesa della riabilitazione dell’operatore; l’accettazione dell’ordine resta registrata.", "amministrazione", "amministrazione", "in_attesa");
    if (p.stato_richiesta_amministrativa === "inviata") return azione("Attendere i dati fiscali", "Richiesta dati già inviata; non preparare un nuovo sollecito automaticamente.", "amministrazione", "amministrazione", "in_attesa");
    return azione("Completare i dati dell’ordine", "Verificare anagrafica e dati amministrativi prima di fatturare.", "amministrazione", "amministrazione");
  }
  if (p.stato_commerciale === "preventivo_inviato" || p.coda === "PREVENTIVO INVIATO")
    return azione("Attendere la scelta del cliente", "Preventivo inviato: nessuna conferma d’ordine viene dedotta dalla sola offerta.", "pratiche", "offerta", "in_attesa");
  if (p.stato_commerciale === "richiesta_verifica" || p.coda === "RICHIESTE VERIFICHE - ATTESA CLIENTE")
    return azione("Attendere le verifiche richieste", "L’operatore ha richiesto verifiche al cliente.", "pratiche", "dati", "in_attesa");
  if (p.coda === "DA PREVENTIVARE" || (!p.coda && p.stato_completezza === "completa_da_preventivare"))
    return azione("Preparare il preventivo", "Dati completi secondo lo stato registrato; verificare i riferimenti prima dell’emissione.", "pratiche", "offerta", "da_lavorare", (p.minuti_lavorativi_preventivo ?? 0) >= 60);
  if (p.coda === "DATI INTEGRATI - DA VERIFICARE" || p.stato_completezza === "dati_integrati_da_verificare")
    return azione("Verificare i dati ricevuti", "Sono presenti integrazioni da controllare prima di proseguire.", "pratiche", "dati", "da_lavorare", (p.minuti_lavorativi_verifica ?? 0) >= 24 * 60);
  if (p.verifica_tecnica_necessaria || p.coda === "PREVENTIVO - VERIFICA TECNICA")
    return azione("Eseguire la verifica tecnica", "Richiesta tecnica da valutare: non è ancora un preventivo pronto.", "pratiche", "dati");
  if (p.coda === "INCOMPLETA - OPERATORE" || p.stato_completezza === "incompleta_operatore")
    return azione("Verificare la nota dell’operatore", "Incompleta per valutazione manuale: rispettare il blocco e le note.", "pratiche", "dati");
  if (p.coda === "DATI MANCANTI" || p.stato_completezza === "dati_mancanti")
    return azione("Attendere / completare la raccolta dati", "Dati non ancora completi; aprire la pratica per vedere cosa manca.", "pratiche", "dati", "in_attesa");
  return azione("Verificare la pratica", "Stato da controllare manualmente; nessuna transizione automatica.", "pratiche", "dati");
}

export const FILTRI_OGGI: Record<string, string> = {
  oggi: "Da lavorare", oggi_urgenti: "Priorità urgenti", oggi_attesa: "In attesa", oggi_concluse: "Concluse",
  area_pratiche: "Pratiche", area_logistica: "Logistica", area_assistenza: "Assistenza", area_amministrazione: "Amministrazione",
};
export function numeroPagina(value: string | undefined): number {
  return value && /^\d{1,6}$/.test(value) ? Math.max(1, Number(value)) : 1;
}
export function filtraOggi<T extends PraticaOggi>(pratiche: T[], filtro: string, giorno: string): T[] {
  return pratiche.filter(p => {
    const a = prossimaAzione(p, giorno);
    if (filtro === "oggi") return a.stato === "da_lavorare";
    if (filtro === "oggi_urgenti") return a.urgente;
    if (filtro === "oggi_attesa") return a.stato === "in_attesa";
    if (filtro === "oggi_concluse") return a.stato === "conclusa";
    if (filtro === "area_pratiche") return p.tipo_flusso !== "assistenza";
    if (filtro === "area_logistica") return a.area === "logistica" || Boolean(p.attivita_operative?.some(v => v.tipo.startsWith("ritiro_")));
    if (filtro === "area_assistenza") return p.tipo_flusso === "assistenza" || Boolean(p.assistenze_rientro?.some(v => !v.chiusa_at && v.stato !== "chiusa"));
    if (filtro === "area_amministrazione") return a.area === "amministrazione" || p.stato_fatturazione === "fatturato";
    return true;
  });
}
export function controlloFermo(ultima: string | null | undefined, errore: string | null | undefined, adesso: number) {
  const at = ultima ? Date.parse(ultima) : NaN;
  return errore != null || !Number.isFinite(at) || at > adesso + 60_000 || adesso - at > 15 * 60_000;
}
export function durataLavorativa(p: PraticaOggi): string | null {
  const minuti = p.coda === "DA PREVENTIVARE" ? p.minuti_lavorativi_preventivo :
    p.coda === "DATI INTEGRATI - DA VERIFICARE" ? p.minuti_lavorativi_verifica : null;
  if (minuti == null || !Number.isFinite(minuti)) return null;
  const m = Math.max(0, Math.floor(minuti));
  return m >= 60 ? `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m lavorativi` : `${m} min lavorativi`;
}
