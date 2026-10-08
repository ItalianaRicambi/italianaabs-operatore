import assert from "node:assert/strict";
import test from "node:test";
import { prontaPerFatturazione, fatturazioneSospesa, clienteFiscaleCompleto } from "./fatturazione.ts";

const pronta = {
  stato_commerciale: "ordine_acquisito", stato_fatturazione: "da_fatturare",
  stato_amministrativo: "pronto_fatturazione", cliente_id: "cliente-verificato",
};

test("un flag completo non sostituisce indirizzo e identificativo fiscale", () => {
  const cliente = { denominazione: "Cliente", indirizzo_fatturazione: "Via Test 1", cap: "28100",
    comune: "Novara", codice_fiscale: "TSTFSC80A01F952A", dati_fiscali_completi: true };
  assert.equal(clienteFiscaleCompleto(cliente), true);
  for (const campo of ["denominazione", "indirizzo_fatturazione", "cap", "comune", "codice_fiscale"])
    assert.equal(clienteFiscaleCompleto({ ...cliente, [campo]: " " }), false);
  assert.equal(clienteFiscaleCompleto({ ...cliente, possibile_duplicato: true }), false);
  assert.equal(clienteFiscaleCompleto({ ...cliente, campi_amministrativi_mancanti: ["codice_sdi"] }), false);
  assert.equal(clienteFiscaleCompleto(null), false);
});

test("ordine e stato storico da fatturare non bastano senza cliente completo", () => {
  assert.equal(prontaPerFatturazione(pronta), true);
  for (const stato_amministrativo of [undefined, "dati_mancanti", "cliente_riconosciuto", "corrispondenza_ambigua"])
    assert.equal(prontaPerFatturazione({ ...pronta, stato_amministrativo }), false);
  assert.equal(prontaPerFatturazione({ ...pronta, cliente_id: null }), false);
  assert.equal(prontaPerFatturazione({ ...pronta, stato_commerciale: "preventivo_inviato" }), false);
  assert.equal(prontaPerFatturazione({ ...pronta, stato_fatturazione: "fatturato" }), false);
});

test("la sospensione operatore prevale anche su uno stato amministrativo pronto", () => {
  const sospesa = { ...pronta, dati_raw: { sospensione_fatturazione_operatore: { attiva: true } } };
  assert.equal(fatturazioneSospesa(sospesa), true);
  assert.equal(prontaPerFatturazione(sospesa), false);
  assert.equal(prontaPerFatturazione({ ...pronta, dati_raw: {
    sospensione_fatturazione_operatore: { attiva: false },
  } }), true);
});
