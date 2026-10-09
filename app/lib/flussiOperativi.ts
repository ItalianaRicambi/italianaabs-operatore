export type SceltaCliente = {
 pratica_id: string; offerta_id: string | null; opzione_id: string | null; stato: string;
 servizio: string | null; importo: number | null; numero: number | null; versione: number | null;
 evidenza: string; richiesta_at: string; fonte: string; operatore: string | null; protetta_operatore: boolean;
 offerta_successiva: boolean; prezzo_da_verificare: boolean; file_url: string | null;
};
export type AssistenzaRientro = {
 id: string; pratica_id: string; pratica_origine_id: string | null; stato: string; priorita: string;
 evidenza: string; aperta_at: string; presa_in_carico_at: string | null; operatore: string | null;
 nota: string | null; esito_tecnico: string | null; chiusa_at: string | null;
};
export type OffertaVersione = {
 id: string; pratica_id: string; preventivo_id: string; versione: number; inviato_at: string;
 stato: string; errore: string | null; file_url: string | null; registrata_at: string;
};
export type AlternativaOfferta = {
 id: string; offerta_id: string; numero: number; numero_esplicito: boolean; servizio: string;
 descrizione: string; importo: number; iva_inclusa: boolean | null; condizioni: string | null;
};
export const NOMI_RITIRO: Record<string, string> = {
 ritiro_lavorazione: "Ritiro per lavorazione", ritiro_programma_scambio: "Rientro Programma Scambio",
 ritiro_verifica_garanzia: "Rientro per verifica in garanzia", ritiro_da_classificare: "Ritiro da classificare",
 ritiro_altro_reso: "Altro reso — verifica operatore",
};
export const NOMI_SCELTA: Record<string, string> = {
 preferenza: "Preferenza — da confermare", condizionata: "Preferenza condizionata", confermata: "Scelta confermata",
 da_chiarire: "Soluzione da chiarire", revocata: "Scelta revocata", modifica_da_verificare: "Modifica da verificare",
};
export const NOMI_ASSISTENZA: Record<string, string> = {
 da_prendere_in_carico: "Da prendere in carico", verifica_tecnica: "Verifica tecnica", ritiro_da_prenotare: "Ritiro da prenotare",
 ritiro_prenotato: "Ritiro prenotato", ricevuto: "Ricevuto in laboratorio", in_lavorazione: "In verifica / lavorazione",
 esito_comunicato: "Esito comunicato", chiusa: "Chiusa",
};
