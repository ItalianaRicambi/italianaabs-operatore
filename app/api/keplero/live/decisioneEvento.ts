import { riconosciConfermaOrdine } from "./riconoscimentoOrdine.ts";
import { riconosciNuovaPratica } from "./riconoscimentoNuovaPratica.ts";

type Payload = Record<string, unknown>;

export type InputCompletezzaCommerciale = {
  targa: string;
  numeroCodici: number;
  numeroAllegati: number;
  numeroDescrizioniAllegati: number;
  descrizioneGuasto: string | null;
  spieAccese: boolean | null;
  numeroDtc: number;
};

export type EsitoCompletezzaCommerciale = {
  completa: boolean;
  datiMancanti: string[];
  identificazioneDaImmagine: boolean;
};

export type ContattoOperativo = {
  nome: string;
  ruolo: "fornitore" | "interno";
  bloccaAutomazioniCommerciali: boolean;
};

/**
 * Regola deterministica unica per la coda "Da preventivare".
 *
 * Le immagini identificative sono una prova valida anche quando l'OCR di
 * Keplero non restituisce un codice. In quel caso la pratica passa alla coda
 * corretta e l'operatore verifica il codice direttamente dall'immagine.
 */
export function valutaCompletezzaCommerciale(
  input: InputCompletezzaCommerciale
): EsitoCompletezzaCommerciale {
  const datiMancanti: string[] = [];
  const haAllegati =
    input.numeroAllegati > 0 || input.numeroDescrizioniAllegati > 0;
  const haIdentificazione = input.numeroCodici > 0 || haAllegati;

  if (!input.targa) datiMancanti.push("targa");
  if (!haIdentificazione) datiMancanti.push("codice_o_immagine_componente");
  if (!input.descrizioneGuasto?.trim()) datiMancanti.push("descrizione_guasto");
  if (input.spieAccese === null) datiMancanti.push("stato_spie");
  if (input.spieAccese === true && input.numeroDtc === 0) {
    datiMancanti.push("dtc_con_spie_accese");
  }

  return {
    completa: datiMancanti.length === 0,
    datiMancanti,
    identificazioneDaImmagine: input.numeroCodici === 0 && haAllegati,
  };
}

export function decidiEventoKeplero(
  payload: Payload,
  completezza: InputCompletezzaCommerciale,
  contattoOperativo: ContattoOperativo | null = null
) {
  const bloccoContatto =
    contattoOperativo?.bloccaAutomazioniCommerciali === true;
  const completezzaValutata = valutaCompletezzaCommerciale(completezza);
  const ordineRilevato = riconosciConfermaOrdine(payload);
  const ordine = bloccoContatto
    ? {
        confermato: false,
        fonte: "nessuna" as const,
        messaggio: ordineRilevato.messaggio,
      }
    : ordineRilevato;
  const nuovaPratica = riconosciNuovaPratica(payload);

  return {
    versioneRegole: "2026-09-30-v2",
    ordine,
    nuovaPratica,
    completezza: bloccoContatto
      ? {
          ...completezzaValutata,
          completa: false,
          datiMancanti: [
            ...completezzaValutata.datiMancanti,
            "contatto_operativo_non_cliente",
          ],
        }
      : completezzaValutata,
    contattoOperativo,
    bloccoContattoOperativo: bloccoContatto,
  };
}
