import assert from "node:assert/strict";
import test from "node:test";

import {
  estraiCodiciIdentificativi,
  normalizzaAllegati,
  statoLetturaImmagini,
} from "./normalizzazioneMedia.ts";

test("unisce e deduplica i codici presenti nei campi strutturati", () => {
  assert.deepEqual(
    estraiCodiciIdentificativi({
      codici_identificativi: ["1K0907379AT"],
      numero_hardware: "1K0 907 379 AT",
      part_number: "10.0961-0307.3",
    }),
    ["1K0907379AT", "10.0961-0307.3"]
  );
});

test("recupera un codice dal testo OCR etichettato", () => {
  assert.deepEqual(
    estraiCodiciIdentificativi({
      testo_immagini:
        "Codice della centralina: 1K0907379AT; versione hardware H30",
    }),
    ["1K0907379AT"]
  );
});

test("esclude targa e DTC forniti come esclusioni", () => {
  assert.deepEqual(
    estraiCodiciIdentificativi(
      {
        codici_identificativi: [
          "EM859AG",
          "C123EF0",
          "1K0907379AT",
        ],
      },
      ["EM859AG", "C123EF0"]
    ),
    ["1K0907379AT"]
  );
});

test("estrae URL anche quando Keplero li inserisce in una descrizione", () => {
  assert.deepEqual(
    normalizzaAllegati([
      "Immagine ricevuta: https://v2.api.keplero.ai/file.jpg",
      "Tre immagini, contenuto non leggibile",
    ]),
    {
      urls: ["https://v2.api.keplero.ai/file.jpg"],
      descrizioni: ["Tre immagini, contenuto non leggibile"],
    }
  );
});

test("segnala quando Keplero descrive gli allegati senza trasmetterli", () => {
  assert.equal(
    statoLetturaImmagini(0, 0, 1),
    "file_non_trasmessi_da_keplero"
  );
});

test("riconosce il payload anomalo del caso 1K0907379AT", () => {
  const body = {
    allegati: [
      "Tre immagini delle schermate dati hardware, contenuto non leggibile",
    ],
    codici_identificativi: [],
  };
  const codici = estraiCodiciIdentificativi(body);
  const allegati = normalizzaAllegati(body.allegati);

  assert.deepEqual(codici, []);
  assert.deepEqual(allegati.urls, []);
  assert.equal(allegati.descrizioni.length, 1);
  assert.equal(
    statoLetturaImmagini(
      codici.length,
      allegati.urls.length,
      allegati.descrizioni.length
    ),
    "file_non_trasmessi_da_keplero"
  );
});
