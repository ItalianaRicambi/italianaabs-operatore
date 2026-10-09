import assert from "node:assert/strict";
import test from "node:test";
import { leggiOrdineContestuale } from "./ordineContestuale.ts";

const esito = {
  confermato: true,
  stato_commerciale: "ordine_acquisito",
  stato_fatturazione: "da_fatturare",
  contesto: { confermato: true, regola: "intenzione_offerta_e_dati_fiscali_v1" },
  avanzamento: { aggiornato: true, motivo: "conferma_esplicita_cliente" },
  messaggio: "Dati fiscali del cliente",
};

test("riporta a K l'ordine verificato dal trigger dopo l'invio dei dati fiscali", () => {
  const risultato = leggiOrdineContestuale(esito);
  assert.equal(risultato?.riconoscimento.confermato, true);
  assert.equal(risultato?.riconoscimento.fonte, "contesto_verificato");
  assert.deepEqual(risultato?.avanzamento, esito.avanzamento);
});

test("mantiene il riconoscimento già acquisito da scelta e fiscali", () => {
  assert.ok(leggiOrdineContestuale({ ...esito,
    contesto: { confermato: true, regola: "scelta_lavorazione_e_dati_fiscali_v1" } }));
});

test("riconosce la scelta letterale dell'offerta anche senza anagrafica fiscale", () => {
  assert.ok(leggiOrdineContestuale({ ...esito,
    contesto: { confermato: true, regola: "conferma_letterale_offerta_v1" } }));
});

test("la sola intenzione o un contesto precedente non fanno risultare acquisito l'ordine", () => {
  assert.equal(leggiOrdineContestuale({ ...esito, stato_commerciale: "preventivo_inviato" }), null);
  assert.equal(leggiOrdineContestuale({ ...esito, stato_fatturazione: "non_applicabile" }), null);
  assert.equal(leggiOrdineContestuale({ ...esito, confermato: false }), null);
  assert.equal(leggiOrdineContestuale({ ...esito, contesto: { confermato: false } }), null);
});

test("non promuove risposte incomplete o regole non verificate", () => {
  for (const value of [null, [], "true", {}, { ...esito, avanzamento: null },
    { ...esito, contesto: { confermato: true, regola: "solo_riepilogo" } }]) {
    assert.equal(leggiOrdineContestuale(value), null);
  }
});
