import assert from "node:assert/strict";
import test from "node:test";

import { riconosciConfermaOrdine } from "./riconoscimentoOrdine.ts";

const positive = [
  "Accetto il preventivo",
  "Buongiorno, accettiamo l’offerta 2 - Programma Scambio",
  "Confermiamo il preventivo, grazie",
  "Approviamo l'offerta ricevuta",
  "Confermo l'ordine, grazie",
  "L'offerta è approvata",
  "Potete procedere",
  "Vorrei dare seguito al preventivo",
  "Vorrei proseguire con questo preventivo",
  "Lavorazione del dispositivo",
  "In merito all'ordine 260915-IN64, è possibile modificarlo e procedere al ritiro?",
  "Va bene, procedete",
];

const negative = [
  "Ok grazie",
  "Va bene",
  "Come posso confermare il preventivo?",
  "Non accetto il preventivo",
  "Non accettiamo l'offerta 2 - Programma Scambio",
  "Se accettiamo l'offerta, quando spedite?",
  "Se confermiamo il preventivo, quanto tempo serve?",
  "Se approviamo l'offerta, potete spedire domani?",
  "Se confermo l'ordine, quando spedite?",
  "Ci penso e vi faccio sapere",
  "Il preventivo è troppo caro",
  "Ho effettuato il pagamento",
  "Bonifico eseguito",
  "Potete organizzare la spedizione?",
  "Sono in attesa del ricambio",
  "Quando passate per il ritiro?",
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

test("il testo esplicito recupera un campo strutturato falso obsoleto", () => {
  assert.equal(
    riconosciConfermaOrdine({
      preventivo_accettato: false,
      ultimo_messaggio_cliente: "Accetto il preventivo",
    }).confermato,
    true
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

test("il riepilogo esplicito recupera un campo strutturato falso obsoleto", () => {
  assert.equal(
    riconosciConfermaOrdine({
      ordine_confermato: false,
      ultimo_messaggio_cliente: "Il codice SDI KRRH6B9",
      riepilogo_operativo: "Accettata la lavorazione del dispositivo.",
    }).confermato,
    true
  );
});

test("riconosce la scelta della lavorazione nel riepilogo", () => {
  const risultato = riconosciConfermaOrdine({
    ordine_confermato: false,
    ultimo_messaggio_cliente: "INDIRIZZO DI FATTURAZIONE già in anagrafica",
    riepilogo_operativo:
      "Spie accese; scelta della lavorazione elettronica sul dispositivo originale.",
  });

  assert.equal(risultato.confermato, true);
  assert.equal(risultato.fonte, "riepilogo_esplicito");
});

test("riconosce la richiesta di dare seguito al preventivo nel riepilogo", () => {
  assert.equal(
    riconosciConfermaOrdine({
      ordine_confermato: false,
      riepilogo_operativo:
        "Il cliente chiede di dare seguito al preventivo per la riparazione dell'ABS.",
    }).confermato,
    true
  );
});
