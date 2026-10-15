import assert from "node:assert/strict";
import test from "node:test";
import { classificaRichiesta } from "./classificazioneRichiesta.ts";

test("un preventivo con garanzia e mantenimento codifica resta commerciale", () => {
  assert.equal(classificaRichiesta({ tipo_flusso: "assistenza", ultimo_messaggio_cliente: "Vorrei richiedere un preventivo per rigenerazione preventiva. Modulo perfettamente funzionante, no programma scambio per mantenere la codifica. Quale garanzia?" }), "commerciale");
});
test("un guasto sul pezzo acquistato è assistenza anche se K lo classifica commerciale", () => {
  assert.equal(classificaRichiesta({ tipo_flusso: "commerciale", ultimo_messaggio_cliente: "Ho acquistato una pompa ABS seguendo il programma scambio, sto avendo problemi con la codifica" }), "assistenza");
});
test("la domanda sulla riparabilità è un nuovo preventivo", () => {
  assert.equal(classificaRichiesta({ ultimo_messaggio_cliente: "ABS bloccato idraulicamente. È riparabile? Ne avete uno pronto revisionato?" }), "commerciale");
});
test("codifica e montaggio da soli non provano un acquisto precedente", () => {
  assert.equal(classificaRichiesta({ descrizione_guasto: "Informazioni su montaggio e codifica" }), "commerciale");
});
test("il tipo assistenza esplicito resta valido per un sollecito al tecnico", () => {
  assert.equal(classificaRichiesta({ tipo_flusso: "assistenza", ultimo_messaggio_cliente: "Potete farmi contattare dal vostro tecnico?" }), "assistenza");
});
test("un acquisto negato non prova un post vendita", () => {
  assert.equal(classificaRichiesta({ ultimo_messaggio_cliente: "Non ho acquistato da voi, ho un problema di codifica. Vorrei richiedere un preventivo" }), "commerciale");
});
