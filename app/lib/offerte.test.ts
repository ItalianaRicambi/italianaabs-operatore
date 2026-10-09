import test from "node:test";
import assert from "node:assert/strict";
import { leggiOffertaDaTesto, normalizzaOpzioni } from "./offerte.ts";

const offerta = (extra: string) => `Offerta tecnica modulo ABS\nTarga: AB123CD\n${extra}\nValidità offerta: 15 giorni dalla data della presente`;
test("le alternative RI+PS+PSMI conservano la numerazione del documento", () => {
 const r = leggiOffertaDaTesto(offerta(`Opzione 1\nLavorazione idraulica del dispositivo del cliente\nOpzione 2\nProgramma Scambio\nOpzione 3\nProgramma Scambio Made in Italy\nImporto dell’intervento\nLavorazione idraulica dispositivo cliente: €447,00 IVA inclusa\nProgramma Scambio: € 547,00 IVA inclusa\nProgramma Scambio Made in Italy: €497,00 IVA inclusa`), "AB123CD");
 assert.equal(r.errore, null); assert.deepEqual(r.opzioni.map(o => [o.numero,o.servizio,o.importo,o.iva_inclusa]), [[1,"RI",447,true],[2,"PS",547,true],[3,"PSMI",497,true]]);
 assert.equal(r.validita_giorni,15);
});
test("RE, PS e PSMI sono alternative; test/spedizioni non sono una quarta opzione", () => {
 const r = leggiOffertaDaTesto(offerta("Offerta 1 – Riparazione elettronica: €497,00 IVA inclusa\nOfferta 2 – Programma Scambio: €597,00 IVA inclusa\nOfferta 3 – Programma Scambio Made in Italy: €547,00 IVA inclusa\nTest e spedizioni: €150,00"),"AB123CD");
 assert.equal(r.errore,null); assert.deepEqual(r.opzioni.map(o=>o.servizio),["RE","PS","PSMI"]);
});
test("una sola opzione PSMI non implica numerazione esplicita", () => {
 const r=leggiOffertaDaTesto(offerta("Programma Scambio Made in Italy: € 847,00 IVA inclusa"),"AB123CD");
 assert.equal(r.errore,null); assert.equal(r.opzioni.length,1); assert.equal(r.opzioni[0].servizio,"PSMI"); assert.equal(r.opzioni[0].numero_esplicito,false);
});
test("targa assente/diversa, prezzi contraddittori e alternative prive di prezzo restano visibili da verificare", () => {
 for(const testo of [offerta("Opzione 1 Lavorazione idraulica\nOpzione 2 Programma Scambio\nLavorazione idraulica: €447,00"),
  offerta("Riparazione elettronica: €497,00\nRiparazione elettronica: €547,00"),
  offerta("Programma Scambio: €547,00").replace("AB123CD","XY999ZZ"),
  "PDF scansionato senza testo"]) assert.ok(leggiOffertaDaTesto(testo,"AB123CD").errore);
});
test("la registrazione strutturata rifiuta importi, numeri e servizi non validi", () => {
 for(const raw of [[],[{numero:1,servizio:"RI",importo:0}],[{numero:1,servizio:"PSMI",importo:"NaN"}],[{numero:1,servizio:"ALTRO",importo:500}],
  [{numero:1,servizio:"RI",importo:447},{numero:1,servizio:"PS",importo:547}]]) assert.throws(()=>normalizzaOpzioni(raw));
});
