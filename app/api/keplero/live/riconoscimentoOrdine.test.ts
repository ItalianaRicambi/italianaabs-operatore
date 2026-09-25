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

test("mantiene la conferma presente nel riepilogo quando l'ultimo messaggio completa i dati fiscali", () => {
  const risultato = riconosciConfermaOrdine({
    ultimo_messaggio_cliente: "Il codice SDI KRRH6B9",
    descrizione_guasto:
      "Ruota bloccata; nessuna spia sul cruscotto. Accettata la lavorazione del dispositivo.",
  });

  assert.equal(risultato.confermato, true);
  assert.equal(risultato.fonte, "riepilogo_esplicito");
  assert.match(risultato.messaggio, /Accettata la lavorazione/);
});

test("mantiene la conferma ordine nel riepilogo quando l'ultimo messaggio contiene una correzione della targa", () => {
  const risultato = riconosciConfermaOrdine({
    ultimo_messaggio_cliente: "Immagine ricevuta con targa CW578CX.",
    descrizione_guasto:
      "Conferma dell'ordine per gruppo SBC; resta da verificare la targa.",
  });

  assert.equal(risultato.confermato, true);
  assert.equal(risultato.fonte, "riepilogo_esplicito");
});

test("non interpreta una semplice richiesta di preventivo come conferma", () => {
  assert.equal(
    riconosciConfermaOrdine({
      ultimo_messaggio_cliente: "Grazie",
      riepilogo_operativo: "Richiesta di preventivo e tempi di lavorazione.",
    }).confermato,
    false
  );
});

test("una negazione nell'ultimo messaggio prevale sul riepilogo precedente", () => {
  assert.equal(
    riconosciConfermaOrdine({
      ultimo_messaggio_cliente: "Non accetto il preventivo",
      riepilogo_operativo: "Preventivo accettato dal cliente.",
    }).confermato,
    false
  );
});

test("un campo strutturato falso prevale anche sul riepilogo", () => {
  assert.equal(
    riconosciConfermaOrdine({
      ordine_confermato: false,
      ultimo_messaggio_cliente: "Il codice SDI KRRH6B9",
      riepilogo_operativo: "Accettata la lavorazione del dispositivo.",
    }).confermato,
    false
  );
});
