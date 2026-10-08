import assert from "node:assert/strict";
import test from "node:test";
import { esitoRegistrazionePreventivo } from "./esitoRegistrazione.ts";

test("un PDF senza pratica non viene confermato come registrato", () => {
  const result = esitoRegistrazionePreventivo({ aggiornato: false, esito: "nessuna_pratica_compatibile", ricevuto: true });
  assert.equal(result.ok, false);
  assert.equal(result.status, 409);
});

test("due pratiche compatibili producono un conflitto visibile al mittente", () => {
  assert.equal(esitoRegistrazionePreventivo({ aggiornato: false, esito: "pratica_ambigua", candidati: 2 }).status, 409);
});

test("un nuovo tentativo su un PDF già collegato è idempotente", () => {
  assert.deepEqual(esitoRegistrazionePreventivo({ aggiornato: false, esito: "gia_registrato", preventivo_id: "preventivo", pratica_id: "pratica" }), { ok: true, status: 200 });
});

test("una registrazione senza identificativi e una risposta malformata non sono successi", () => {
  for (const result of ["ok", null, [], {}, { aggiornato: true }, { esito: "gia_registrato" }]) {
    assert.equal(esitoRegistrazionePreventivo(result).status, 502);
  }
});

test("un collegamento verificabile e una data invalida ricevono esiti distinti", () => {
  assert.equal(esitoRegistrazionePreventivo({ aggiornato: true, esito: "preventivo_inviato", preventivo_id: "preventivo", pratica_id: "pratica" }).ok, true);
  assert.equal(esitoRegistrazionePreventivo({ aggiornato: false, esito: "data_offerta_futura" }).status, 422);
});
