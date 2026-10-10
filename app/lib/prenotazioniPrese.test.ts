import assert from "node:assert/strict";
import test from "node:test";
import { leggiPrenotazionePresa } from "./prenotazioniPrese.ts";

test("legge il messaggio operatore dell'esempio senza confondere P3 con il codice", () => {
  assert.deepEqual(leggiPrenotazionePresa("Buongiorno, abbiamo prenotato la presa con GLS per la giornata di lunedì, 12/10/2026, cod. (da riportare all'esterno della scatola) P3 9260993058. Vi ricordiamo il bigliettino con la targa."),
    { corriere: "GLS", riferimento: "P3 9260993058", data_ritiro: "2026-10-12", errore: null });
});
test("legge la risposta cliente, la fonte resta da verificare nel flusso", () => {
  assert.equal(leggiPrenotazionePresa("Lunedì 12/10/2026 lascerò il pacco pronto per il corriere GLS con codice P3 9260993058 scritto all'esterno.").data_ritiro, "2026-10-12");
});
test("date impossibili, relative, multiple e codici multipli richiedono verifica", () => {
  for (const t of ["GLS presa 31/02/2026 codice P3 9260993058", "GLS presa domani codice P3 9260993058", "GLS presa 12/10/2026 o 13/10/2026 codice P3 9260993058", "GLS presa 12/10/2026 codice P3 9260993058 codice P3 9260993059"]) {
    assert.ok(leggiPrenotazionePresa(t).errore, t);
  }
});
test("una notifica di spedizione non viene scambiata per prenotazione presa", () => {
  assert.ok(leggiPrenotazionePresa("GLS: la spedizione LU 260037607 è partita il 09/03/2026.").errore);
  assert.equal(leggiPrenotazionePresa("GLS presa 12/10/2026; targa FT807XZ; telefono 3791699152; centralina 1K0907379AE").riferimento, null);
});
