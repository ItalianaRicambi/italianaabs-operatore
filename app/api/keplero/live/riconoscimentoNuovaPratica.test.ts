import assert from "node:assert/strict";
import test from "node:test";

import { riconosciNuovaPratica } from "./riconoscimentoNuovaPratica.ts";

const positivi = [
  "Questi sono i dati di un'altra vettura",
  "Avrei una seconda auto da farvi controllare",
  "Vi mando la diagnosi per un nuovo veicolo",
  "Non è la stessa macchina della richiesta precedente",
  "Mi serve un preventivo per un'altra moto",
];

for (const messaggio of positivi) {
  test(`riconosce la nuova pratica: ${messaggio}`, () => {
    const risultato = riconosciNuovaPratica({
      ultimo_messaggio_cliente: messaggio,
    });

    assert.equal(risultato.richiesta, true);
    assert.equal(risultato.fonte, "testo_esplicito");
  });
}

const negativi = [
  "Invio una nuova foto della stessa vettura",
  "Ho rifatto la diagnosi della Jeep",
  "Mi serve un altro controllo sullo stesso ABS",
  "La targa corretta è EP023SZ",
];

for (const messaggio of negativi) {
  test(`non apre una nuova pratica: ${messaggio}`, () => {
    assert.equal(
      riconosciNuovaPratica({ ultimo_messaggio_cliente: messaggio }).richiesta,
      false
    );
  });
}

test("accetta il campo strutturato nuova_pratica", () => {
  const risultato = riconosciNuovaPratica({ nuova_pratica: true });

  assert.equal(risultato.richiesta, true);
  assert.equal(risultato.fonte, "campo_strutturato");
});

test("non interpreta un campo strutturato falso come nuova pratica", () => {
  assert.equal(
    riconosciNuovaPratica({
      nuova_pratica: false,
      ultimo_messaggio_cliente: "Invio i dati aggiornati",
    }).richiesta,
    false
  );
});
