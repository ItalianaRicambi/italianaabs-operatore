import { prontaPerFatturazione } from "./fatturazione.ts";

type PraticaCoda = {
  tipo_flusso: string;
  stato_commerciale: string;
  stato_fatturazione: string;
  stato_completezza: string;
  stato_amministrativo?: string | null;
  cliente_id?: string | null;
  dati_raw?: Record<string, unknown> | null;
  verifica_tecnica_necessaria?: boolean;
  coda: string;
  priorita: number;
};

// La richiesta incompleta resta lavorabile, distinta da un preventivo pronto da preparare.
export function correggiCodaOperativa<T extends PraticaCoda>(pratica: T): T {
  // Le code assistenza sono già corrette nella view e restano intatte.
  if (pratica.tipo_flusso === "assistenza") {
    return pratica;
  }

  let coda = pratica.coda;
  let priorita = pratica.priorita;

  // Gli stati terminali prevalgono su qualunque dato storico di completezza.
  if (pratica.stato_commerciale === "rifiutato") {
    coda = "RIFIUTATA";
    priorita = 99;
  } else if (pratica.stato_commerciale === "chiuso") {
    coda = "CHIUSA";
    priorita = 99;
  } else if (pratica.stato_fatturazione === "fatturato") {
    // Una pratica fatturata non deve competere con attività ancora da svolgere.
    coda = "FATTURATA";
    priorita = 10;
  } else if (pratica.stato_fatturazione === "da_fatturare") {
    coda = prontaPerFatturazione(pratica)
      ? "ORDINE ACQUISITO - DA FATTURARE"
      : "ORDINE ACQUISITO - IN ATTESA DATI CLIENTE";
    priorita = prontaPerFatturazione(pratica) ? 3 : 4;
  } else if (pratica.stato_commerciale === "preventivo_inviato") {
    coda = "PREVENTIVO INVIATO";
    priorita = 9;
  } else if (pratica.stato_commerciale === "richiesta_verifica") {
    // L'operatore ha chiesto verifiche al cliente: la pratica resta in attesa
    // e NON deve competere con le vere pratiche "Da verificare".
    coda = "RICHIESTE VERIFICHE - ATTESA CLIENTE";
    priorita = 7;
  } else if (
    ["nuova", "raccolta_dati", "da_preventivare"].includes(
      pratica.stato_commerciale
    ) &&
    pratica.stato_completezza === "completa_da_preventivare"
  ) {
    // Solo una pratica commerciale ancora aperta può entrare nella coda preventivi.
    coda = "DA PREVENTIVARE";
    priorita = 2;
  } else if (
    ["nuova", "raccolta_dati"].includes(pratica.stato_commerciale) &&
    pratica.verifica_tecnica_necessaria
  ) {
    coda = "PREVENTIVO - VERIFICA TECNICA";
    priorita = 2;
  } else if (pratica.stato_completezza === "dati_integrati_da_verificare") {
    coda = "DATI INTEGRATI - DA VERIFICARE";
    priorita = 6;
  } else if (pratica.stato_completezza === "dati_mancanti") {
    coda = "DATI MANCANTI";
    priorita = 8;
  }

  return {
    ...pratica,
    coda,
    priorita,
  };
}

