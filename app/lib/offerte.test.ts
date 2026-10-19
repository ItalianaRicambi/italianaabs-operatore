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

test("revisione completa FTE: prezzo italiano, IVA, moto e condizioni dopo il prezzo", () => {
 const testo = `Offerta tecnica revisione completa ABS servoassistito FTE
Targa: ZA12345
Revisione completa del dispositivo originale
Verifica della parte elettronica e controllo della sezione idraulica.
Importo dell’intervento
Revisione completa ABS servoassistito FTE: € 1.247,00 IVA inclusa
Garanzia: 2 anni
Validità offerta: 15 giorni dalla data della presente
NOTA IMPORTANTE – DISPOSITIVI FTE GIÀ APERTI O MANOMESSI
Dispositivo precedentemente manomesso/lavorato da terzi – intervento eseguito NON in garanzia.
Il cliente accetta le condizioni riportate nel documento originale.`;
 const r=leggiOffertaDaTesto(testo,"ZA12345");
 assert.equal(r.errore,null);
 assert.deepEqual(r.opzioni.map(o=>[o.servizio,o.descrizione,o.importo,o.iva_inclusa,o.reso_vecchio,o.numero_esplicito]),
  [["RC","Revisione completa ABS servoassistito FTE",1247,true,false,false]]);
 assert.match(r.opzioni[0].condizioni,/NON in garanzia/);
 assert.match(r.opzioni[0].condizioni,/Il cliente accetta/);
 assert.equal(r.testo,testo); assert.equal(r.validita_giorni,15);
});

test("la revisione completa legge il prezzo sulla riga successiva, senza creare RI o RE",()=>{
 const r=leggiOffertaDaTesto(offerta("Revisione completa del dispositivo originale\n€ 1.247,00 IVA inclusa\nControlli idraulici ed elettronici inclusi."),"AB123CD");
 assert.equal(r.errore,null); assert.deepEqual(r.opzioni.map(o=>o.servizio),["RC"]);
});

test("una menzione di revisione completa nei costi di test non inventa un'offerta",()=>{
 const r=leggiOffertaDaTesto(offerta("Revisione completa del dispositivo originale da valutare.\nCosto test prima della revisione completa: € 150,00 IVA inclusa"),"AB123CD");
 assert.ok(r.errore); assert.equal(r.opzioni.length,0);
});

test("revisione completa: prezzi multipli e IVA discordante richiedono verifica",()=>{
 for(const t of ["Revisione completa ABS: € 1.247,00 IVA inclusa oppure € 1.400,00",
  "Revisione completa ABS: € 1.247,00 IVA inclusa\nRevisione completa ABS: € 1.300,00 IVA inclusa",
  "Revisione completa ABS: € 1.247,00 IVA inclusa\nRevisione completa ABS: € 1.247,00 IVA esclusa"])
  assert.ok(leggiOffertaDaTesto(offerta(t),"AB123CD").errore);
});

test("le condizioni RC troppo lunghe non vengono troncate cancellando limitazioni finali",()=>{
 const r=leggiOffertaDaTesto(offerta("Importo dell’intervento\nRevisione completa ABS: € 1.247,00 IVA inclusa\n"+"Condizioni da rispettare. ".repeat(260)+"NON in garanzia"),"AB123CD");
 assert.match(r.errore||"",/Condizioni/); assert.equal(r.opzioni.length,0);
});

test("servizio nel titolo tecnico e un solo Prezzo esplicito nella sezione economica",()=>{
 const r=leggiOffertaDaTesto(`Offerta tecnica per revisione elettronica modulo ABS
Targa: ZA12345
Intervento proposto
Revisione della parte elettronica interessata dal guasto.
Importo dell’intervento
Prezzo: € 597,00 IVA inclusa
Garanzia: 2 anni
Validità offerta: 15 giorni dalla data della presente`,"ZA12345");
 assert.equal(r.errore,null); assert.deepEqual(r.opzioni.map(o=>[o.servizio,o.importo,o.iva_inclusa]),[["RE",597,true]]);
 assert.match(r.opzioni[0].condizioni,/Garanzia: 2 anni/);
});

test("Prezzo generico non associa arbitrariamente titoli o alternative differenti",()=>{
 const titolo="Offerta tecnica per revisione elettronica modulo ABS\nTarga: AB123CD\nImporto dell’intervento\n";
 for(const t of [
  titolo+"Prezzo: € 597,00\nPrezzo: € 547,00",
  titolo+"Opzione 1 Revisione elettronica\nOpzione 2 Programma Scambio\nPrezzo: € 597,00",
  titolo+"Programma Scambio alternativo\nPrezzo: € 597,00",
  titolo+"Offerta tecnica per revisione idraulica modulo ABS\nPrezzo: € 597,00",
  offerta("Prezzo: € 597,00 IVA inclusa"),
 ]) assert.ok(leggiOffertaDaTesto(t,"AB123CD").errore);
});
