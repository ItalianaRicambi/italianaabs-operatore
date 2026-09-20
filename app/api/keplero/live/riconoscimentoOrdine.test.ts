import assert from "node:assert/strict";
import test from "node:test";

import { riconosciConfermaOrdine } from "./riconoscimentoOrdine.ts";

const positive = [
  "Accetto il preventivo",
  "Confermo l'ordine, grazie",
  "L'offerta è approvata",
  "Potete procedere",
  "Va bene, procedete",
  "Ho effettuato il pagamento",
];

const negative = [
  "Ok grazie",
  "Va bene",
  "Come posso confermare il preventivo?",
  "Non accetto il preventivo",
  "Se confermo l'ordine, quando spedite?",
  "Ci penso e vi faccio sapere",
  "Il preventivo è troppo caro",
];

for (const messaggio of positive) {
  test(`riconosce: ${messaggio}`, () => {
    assert.equal(
      riconosciConfermaOrdine({ ultimo_messaggio_cliente: messaggio })
        .confermato,
      true
    );
  });
}

for (const messaggio of negative) {
  test(`non riconosce: ${messaggio}`, () => {
    assert.equal(
      riconosciConfermaOrdine({ ultimo_messaggio_cliente: messaggio })
        .confermato,
      false
    );
  });
}

test("accetta il campo strutturato di Keplero", () => {
  assert.equal(
    riconosciConfermaOrdine({ preventivo_accettato: true }).confermato,
    true
  );
});

test("un campo strutturato falso prevale sul testo", () => {
  assert.equal(
    riconosciConfermaOrdine({
      preventivo_accettato: false,
      ultimo_messaggio_cliente: "Accetto il preventivo",
    }).confermato,
    false
  );
});

test("un messaggio negativo prevale anche su un campo strutturato errato", () => {
  assert.equal(
    riconosciConfermaOrdine({
      preventivo_accettato: true,
      ultimo_messaggio_cliente: "Il preventivo non è accettato",
    }).confermato,
    false
  );
});
