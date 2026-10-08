type StatoFatturazionePratica = {
  stato_commerciale?: string | null;
  stato_fatturazione?: string | null;
  stato_amministrativo?: string | null;
  cliente_id?: string | null;
  dati_raw?: Record<string, unknown> | null;
};

type ClienteFiscale = {
  denominazione?: string | null;
  indirizzo_fatturazione?: string | null;
  cap?: string | null;
  comune?: string | null;
  partita_iva?: string | null;
  codice_fiscale?: string | null;
  dati_fiscali_completi?: boolean;
  campi_amministrativi_mancanti?: string[] | null;
  da_verificare?: boolean;
  possibile_duplicato?: boolean;
};

export function clienteFiscaleCompleto(cliente: ClienteFiscale | null | undefined): boolean {
  return Boolean(cliente?.dati_fiscali_completi && !cliente.da_verificare &&
    !cliente.possibile_duplicato && !cliente.campi_amministrativi_mancanti?.length &&
    cliente.denominazione?.trim() && cliente.indirizzo_fatturazione?.trim() &&
    cliente.cap?.trim() && cliente.comune?.trim() &&
    (cliente.partita_iva?.trim() || cliente.codice_fiscale?.trim()));
}

export function fatturazioneSospesa(pratica: StatoFatturazionePratica): boolean {
  const sospensione = pratica.dati_raw?.sospensione_fatturazione_operatore;
  return typeof sospensione === "object" && sospensione !== null &&
    "attiva" in sospensione && sospensione.attiva === true;
}

// Lo stato amministrativo è validato dal database sui dati reali del cliente.
// Dati assenti o metadati non disponibili non autorizzano la fatturazione.
export function prontaPerFatturazione(pratica: StatoFatturazionePratica): boolean {
  return pratica.stato_commerciale === "ordine_acquisito" &&
    pratica.stato_fatturazione === "da_fatturare" &&
    pratica.stato_amministrativo === "pronto_fatturazione" &&
    Boolean(pratica.cliente_id?.trim()) && !fatturazioneSospesa(pratica);
}
