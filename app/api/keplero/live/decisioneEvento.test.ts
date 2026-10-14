import assert from "node:assert/strict";
import test from "node:test";

import {
  decidiEventoKeplero,
  valutaCompletezzaCommerciale,
} from "./decisioneEvento.ts";

const base = {
  targa: "AB123CD",
  numeroCodici: 1,
  numeroAllegati: 0,
  numeroDescrizioniAllegati: 0,
  descrizioneGuasto: "La pompa non manda pressione alla ruota posteriore",
  spieAccese: false,
  numeroDtc: 0,
};

test("una richiesta tecnica completa passa a Da preventivare", () => {
  assert.deepEqual(valutaCompletezzaCommerciale(base), {
    completa: true,
    datiMancanti: [],
    identificazioneDaImmagine: false,
  });
});

test("le immagini identificano il componente anche senza OCR", () => {
  const esito = valutaCompletezzaCommerciale({
    ...base,
    numeroCodici: 0,
    numeroAllegati: 2,
  });

  assert.equal(esito.completa, true);
  assert.equal(esito.identificazioneDaImmagine, true);
});

test("con spie accese il DTC resta necessario", () => {
  const esito = valutaCompletezzaCommerciale({
    ...base,
    spieAccese: true,
  });

  assert.equal(esito.completa, false);
  assert.deepEqual(esito.datiMancanti, ["dtc_con_spie_accese"]);
});

test("senza spie un guasto idraulico descritto non richiede DTC", () => {
  const esito = valutaCompletezzaCommerciale({
    ...base,
    spieAccese: false,
    numeroDtc: 0,
  });

  assert.equal(esito.completa, true);
});

test("Golf TEXA: tre DTC già letti chiudono la domanda sulle spie", () => {
  const input = { ...base, spieAccese: null, numeroDtc: 3 };
  assert.equal(valutaCompletezzaCommerciale(input).completa, true);
  assert.deepEqual(valutaCompletezzaCommerciale(input).datiMancanti, []);
  assert.equal(input.spieAccese, null);
});

test("esito senza errori acquisito: non richiede spie neanche fuori dall'idraulica", () => {
  assert.equal(valutaCompletezzaCommerciale({ ...base, descrizioneGuasto: "Anomalia da valutare", spieAccese: null, diagnosiSenzaErrori: true }).completa, true);
});

test("nessun esito: array DTC vuoto non chiude la domanda; contraddizione va all'operatore", () => {
  assert.deepEqual(valutaCompletezzaCommerciale({ ...base, spieAccese: null }).datiMancanti, ["stato_spie"]);
  assert.deepEqual(valutaCompletezzaCommerciale({ ...base, spieAccese: true, diagnosiSenzaErrori: true }).datiMancanti, ["diagnosi_discordante_da_verificare_operatore"]);
});

test("la decisione conserva insieme completezza, ordine e nuova pratica", () => {
  const decisione = decidiEventoKeplero(
    { ultimo_messaggio_cliente: "Confermo il preventivo, procedete pure" },
    base
  );

  assert.equal(decisione.completezza.completa, true);
  assert.equal(decisione.ordine.confermato, true);
  assert.equal(decisione.nuovaPratica.richiesta, false);
  assert.equal(decisione.versioneRegole, "2026-10-09-ordini-v3");
});

test("un fornitore non genera preventivi o ordini cliente", () => {
  const decisione = decidiEventoKeplero(
    {
      ultimo_messaggio_cliente:
        "Se vuoi ti faccio preventivo, confermo l'offerta",
    },
    base,
    {
      nome: "Giacomo Sismi",
      ruolo: "fornitore",
      bloccaAutomazioniCommerciali: true,
    }
  );

  assert.equal(decisione.completezza.completa, false);
  assert.deepEqual(decisione.completezza.datiMancanti, [
    "contatto_operativo_non_cliente",
  ]);
  assert.equal(decisione.ordine.confermato, false);
  assert.equal(decisione.ordine.fonte, "nessuna");
  assert.equal(decisione.bloccoContattoOperativo, true);
});
