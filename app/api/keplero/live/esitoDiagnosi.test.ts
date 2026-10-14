import assert from "node:assert/strict";
import test from "node:test";
import { diagnosiSenzaErroriDichiarata } from "./esitoDiagnosi.ts";

test("acquisisce gli esiti negativi espliciti e li conserva nel riepilogo", () => {
  for (const testo of ["Nessun errore in centralina", "Diagnosi senza errori", "Non risultano codici guasto", "Nessun DTC", "Il tester non rileva guasti"]) {
    assert.equal(diagnosiSenzaErroriDichiarata({ ultimo_messaggio_cliente: testo }), true, testo);
    assert.equal(diagnosiSenzaErroriDichiarata({ ultimo_messaggio_cliente: "Sono un'officina", descrizione_guasto: testo }), true, testo);
  }
});

test("mancanza dei codici o spie spente non inventano una diagnosi senza errori", () => {
  for (const testo of ["Non conosco i codici", "Non ho fatto diagnosi", "Nessuna spia accesa", "La foto è illeggibile", "Diagnosi effettuata"]) {
    assert.equal(diagnosiSenzaErroriDichiarata({ ultimo_messaggio_cliente: testo }), false, testo);
  }
  assert.equal(diagnosiSenzaErroriDichiarata({ dtc: [], diagnosi_presente: true }), false);
});
