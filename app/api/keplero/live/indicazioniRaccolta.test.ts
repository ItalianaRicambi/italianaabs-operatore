import assert from "node:assert/strict";
import test from "node:test";
import { campiPerRichiestaFiscale, indicazioniAnagraficheKeplero, messaggioRaccoltaKeplero } from "./indicazioniRaccolta.ts";

test("message impedisce richieste ripetute di spie e diagnosi", () => {
  const message = messaggioRaccoltaKeplero({}, {}, "codici_acquisiti");
  assert.match(message, /DTC già ricevuti.*chiudono la domanda sulle spie/);
  assert.match(message, /senza inventare spie o un esito diagnostico/);
});

test("Ortolani: il campo message impedisce di chiedere tutta l'anagrafica", () => {
  const message = messaggioRaccoltaKeplero({stato: "riconosciuto", cliente_riconosciuto: true, denominazione: "ORTOLANI SERVICE SAS", dati_fiscali_completi: true}, {necessaria: false, stato: "completata"}, "codici_acquisiti");
  assert.match(message, /ORTOLANI SERVICE SAS/);
  assert.match(message, /Dati fiscali già completi/);
  assert.match(message, /non inviare un nuovo elenco/);
});

test("cliente conosciuto ma incompleto: chiede soltanto i mancanti", () => {
  const message = messaggioRaccoltaKeplero({stato: "riconosciuto", cliente_riconosciuto: true, dati_fiscali_completi: false, campi_mancanti: ["email"]}, {}, "nessun_file");
  assert.match(message, /solo questi dati mancanti: email/);
  assert.match(message, /Non chiedere nuovamente nome/);
});

test("ambiguità o errore di ricerca non fanno ripartire la raccolta", () => {
  for (const stato of ["ambiguo", "da_verificare", "errore"]) {
    assert.match(messaggioRaccoltaKeplero({stato}, {}, "nessun_file"), /verifica dell’operatore/);
  }
});

test("Maratta: conserva il nome letto nel timbro, senza chiedere altre foto", () => {
  const message = messaggioRaccoltaKeplero({stato:"non_trovato", nome_attivita_acquisito:"MARATTA dal 1958 S.r.l."}, {}, "file_ricevuti_senza_codici");
  assert.match(message, /MARATTA dal 1958/);
  assert.match(message, /Non richiederlo nuovamente/);
  assert.match(message, /non deve contenere codici del componente/);
});

test("i dati completi prevalgono su una richiesta amministrativa precedente", () => {
  const message = messaggioRaccoltaKeplero({stato:"riconosciuto", cliente_riconosciuto:true, dati_fiscali_completi:true}, {necessaria:true,campi:["partita_iva"]}, "codici_acquisiti");
  assert.doesNotMatch(message, /Richiesta amministrativa: chiedi/);
});

test("una richiesta precedente non prevale sull'ambiguità anagrafica", () => {
  const message = messaggioRaccoltaKeplero({stato:"ambiguo"}, {necessaria:true,campi:["partita_iva"]}, "codici_acquisiti");
  assert.match(message, /verifica dell’operatore/);
  assert.doesNotMatch(message, /Richiesta amministrativa: chiedi/);
});

test("alla conferma ordine entrambe le indicazioni rispettano il controllo in Fatture in Cloud", () => {
  const richiesta = { necessaria: true, campi: ["denominazione", "indirizzo_fatturazione"] };
  for (const istruzione of [
    "La verifica è in attesa dell’operatore.",
    "Per verificare l’identità chiedi solo partita IVA o codice fiscale, se non già forniti.",
  ]) {
    const contesto = { stato: "verifica_fatture_in_cloud", istruzione };
    const ordine = indicazioniAnagraficheKeplero(contesto, richiesta);
    assert.ok(ordine.includes(istruzione));
    assert.doesNotMatch(ordine, /indirizzo_fatturazione|Richiesta amministrativa: chiedi/);
    assert.ok(messaggioRaccoltaKeplero(contesto, richiesta, "nessun_file").includes(ordine));
    assert.deepEqual(campiPerRichiestaFiscale(contesto, richiesta.campi), []);
  }
});

test("il testo per l’ordine riconosciuto esclude i solleciti per dati già presenti", () => {
  const contesto = { stato: "riconosciuto", cliente_riconosciuto: true, dati_fiscali_completi: true };
  const richiesta = { necessaria: true, campi: ["partita_iva"] };
  assert.match(indicazioniAnagraficheKeplero(contesto, richiesta), /Dati fiscali già completi/);
  for (const stato of ["ambiguo", "da_verificare", "errore"]) {
    assert.deepEqual(campiPerRichiestaFiscale({ stato }, richiesta.campi), []);
  }
  assert.deepEqual(campiPerRichiestaFiscale(contesto, richiesta.campi), []);
});

test("un sollecito fiscale rimane possibile per i soli campi effettivamente mancanti", () => {
  const contesto = { stato: "riconosciuto", cliente_riconosciuto: true, campi_mancanti: ["codice_sdi"] };
  assert.deepEqual(campiPerRichiestaFiscale(contesto, ["codice_sdi"]), ["codice_sdi"]);
  assert.deepEqual(campiPerRichiestaFiscale(contesto, ["codice_sdi", "partita_iva"]), []);
  assert.deepEqual(campiPerRichiestaFiscale({ stato: "non_trovato" }, ["indirizzo_fatturazione"]), ["indirizzo_fatturazione"]);
});
