import assert from "node:assert/strict";
import test from "node:test";
import { leggiEsitoRegistrazioneCommerciale } from "./esitoRegistrazioneCommerciale.ts";

const p = "00000000-0000-4000-8000-000000000001";
const ricevuta = {
  versione_contratto: "2026-10-23-esiti-v1", pratica_id: p, ricevuta: true,
  ordine_registrato: false, preventivo_inviato: false,
  stato_commerciale: "da_preventivare", stato_fatturazione: "non_applicabile",
  istruzione: "Richiesta presa in carico; ordine non acquisito.",
};

test("intenzione riconosciuta e HTTP 200 non diventano un ordine registrato", () => {
  assert.throws(() => leggiEsitoRegistrazioneCommerciale({ ok: true, confermato: true }, p));
  assert.equal(leggiEsitoRegistrazioneCommerciale(ricevuta, p).ordine_registrato, false);
});
test("l'ordine acquisito resta registrato anche quando mancano dati amministrativi", () => {
  const r = leggiEsitoRegistrazioneCommerciale({ ...ricevuta, ordine_registrato: true,
    stato_commerciale: "ordine_acquisito", stato_fatturazione: "da_fatturare", stato_amministrativo: "dati_mancanti" }, p);
  assert.equal(r.ordine_registrato, true);
});
test("una ricevuta di un altro veicolo della stessa chat viene respinta", () => {
  assert.throws(() => leggiEsitoRegistrazioneCommerciale({ ...ricevuta, pratica_id: "altro-episodio" }, p));
});
test("schema non aggiornato, risposta vuota e contraddizione non autorizzano conferme", () => {
  for (const r of [null, [], {}, { ...ricevuta, versione_contratto: "vecchio" },
    { ...ricevuta, ordine_registrato: true }, { ...ricevuta, ricevuta: false }]) {
    assert.throws(() => leggiEsitoRegistrazioneCommerciale(r, p));
  }
});
