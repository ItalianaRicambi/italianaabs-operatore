import assert from "node:assert/strict";
import test from "node:test";

import {
  chiaveMeseRoma,
  dataFatturaEffettiva,
  filtroMensileSolaLettura,
  haFatturaNelMese,
  haPreventivoNelMese,
  mesiDashboard,
} from "./dashboardMensile.ts";

test("calcola mese corrente e precedente nel fuso Europe/Rome", () => {
  assert.deepEqual(mesiDashboard(new Date("2026-10-01T00:30:00+02:00")), {
    corrente: "2026-10",
    precedente: "2026-09",
    etichettaCorrente: "Ottobre 2026",
    etichettaPrecedente: "Settembre 2026",
  });
});

test("rispetta il cambio mese italiano anche quando in UTC è ancora il giorno prima", () => {
  assert.equal(chiaveMeseRoma("2026-09-30T22:30:00Z"), "2026-10");
});

test("classifica il preventivo usando la data di invio", () => {
  const pratica = {
    preventivo_inviato_at: "2026-09-29T16:00:00Z",
    stato_fatturazione: "non_applicabile",
    data_fattura: null,
    ordine_acquisito_at: null,
  };

  assert.equal(haPreventivoNelMese(pratica, "2026-09"), true);
  assert.equal(haPreventivoNelMese(pratica, "2026-10"), false);
});

test("usa la data fattura e, se assente, la data ordine documentata", () => {
  const conData = {
    preventivo_inviato_at: null,
    stato_fatturazione: "fatturato",
    data_fattura: "2026-09-29T10:00:00Z",
    ordine_acquisito_at: "2026-08-31T10:00:00Z",
  };
  const senzaData = {
    ...conData,
    data_fattura: null,
  };

  assert.equal(dataFatturaEffettiva(conData), conData.data_fattura);
  assert.equal(haFatturaNelMese(conData, "2026-09"), true);
  assert.equal(haFatturaNelMese(senzaData, "2026-08"), true);
});

test("non archivia come fattura uno stato non fatturato", () => {
  const pratica = {
    preventivo_inviato_at: null,
    stato_fatturazione: "da_fatturare",
    data_fattura: "2026-09-29T10:00:00Z",
    ordine_acquisito_at: "2026-09-28T10:00:00Z",
  };

  assert.equal(dataFatturaEffettiva(pratica), null);
  assert.equal(haFatturaNelMese(pratica, "2026-09"), false);
});

test("solo gli archivi del mese precedente sono in sola lettura", () => {
  assert.equal(filtroMensileSolaLettura("preventivi_mese_precedente"), true);
  assert.equal(filtroMensileSolaLettura("fatture_mese_precedente"), true);
  assert.equal(filtroMensileSolaLettura("preventivi_mese_corrente"), false);
});

