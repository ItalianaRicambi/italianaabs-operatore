import assert from "node:assert/strict";
import test from "node:test";
import { messaggioRaccoltaKeplero } from "./indicazioniRaccolta.ts";

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
