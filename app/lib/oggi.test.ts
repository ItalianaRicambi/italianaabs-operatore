import assert from "node:assert/strict";
import test from "node:test";
import { controlloFermo, durataLavorativa, filtraOggi, numeroPagina, prossimaAzione, type PraticaOggi } from "./oggi.ts";

const giorno = "2026-11-07";
const base: PraticaOggi = { id: "pratica-test", tipo_flusso: "commerciale", stato_commerciale: "raccolta_dati", stato_completezza: "dati_mancanti" };
const ordine: PraticaOggi = { ...base, stato_commerciale: "ordine_acquisito", stato_fatturazione: "da_fatturare", stato_amministrativo: "pronto_fatturazione", cliente_id: "cliente-test" };
const ritiro = { tipo: "ritiro_lavorazione", stato: "programmata", priorita: "normale", data_ritiro_prevista: "2026-11-09" };
const azione = (p: Partial<PraticaOggi>) => prossimaAzione({ ...base, ...p }, giorno);

test("solo gli stati registrati, non la completezza storica, determinano le conclusioni", () => {
  for (const finale of [{ stato_fatturazione: "fatturato" }, { stato_commerciale: "rifiutato" }, { stato_commerciale: "chiuso" }]) {
    assert.equal(azione({ ...finale, coda: "DA PREVENTIVARE", stato_completezza: "completa_da_preventivare" }).stato, "conclusa");
  }
  assert.equal(azione({ stato_commerciale: "preventivo_inviato", stato_completezza: "completa_da_preventivare" }).stato, "in_attesa");
  assert.equal(azione({ stato_commerciale: "richiesta_verifica", stato_completezza: "completa_da_preventivare" }).sezione, "dati");
});

test("fatturazione pronta, sospesa e dati richiesti restano distinti", () => {
  assert.equal(azione(ordine).titolo, "Preparare la fatturazione");
  assert.equal(azione({ ...ordine, cliente_id: null }).titolo, "Completare i dati dell’ordine");
  assert.equal(azione({ ...ordine, dati_raw: { sospensione_fatturazione_operatore: { attiva: true } } }).titolo, "Verificare la sospensione");
  assert.equal(azione({ ...ordine, stato_amministrativo: "dati_mancanti", stato_richiesta_amministrativa: "inviata" }).stato, "in_attesa");
});

test("offerta o scelta dubbia non vengono promosse a ordine", () => {
  assert.equal(azione({ stato_commerciale: "preventivo_inviato", scelta_cliente: { stato: "da_chiarire", offerta_successiva: false, prezzo_da_verificare: false } }).titolo, "Chiarire la scelta del cliente");
  assert.equal(azione({ offerta_da_verificare: true }).titolo, "Verificare l’offerta");
  assert.equal(azione({ stato_commerciale: "preventivo_inviato" }).titolo, "Attendere la scelta del cliente");
});

test("i tempi di priorità usano soltanto i minuti lavorativi già calcolati", () => {
  const p = { coda: "DA PREVENTIVARE", created_at: "2020-01-01", minuti_lavorativi_preventivo: 59 };
  assert.equal(azione(p).urgente, false);
  assert.equal(azione({ ...p, minuti_lavorativi_preventivo: 60 }).urgente, true);
  assert.equal(azione({ coda: "DATI INTEGRATI - DA VERIFICARE", minuti_lavorativi_verifica: 1439 }).urgente, false);
  assert.equal(azione({ coda: "DATI INTEGRATI - DA VERIFICARE", minuti_lavorativi_verifica: 1440 }).urgente, true);
  assert.equal(durataLavorativa({ ...base, ...p }), "59 min lavorativi");
  assert.equal(durataLavorativa({ ...base, ...p, minuti_lavorativi_preventivo: 121 }), "2h 01m lavorativi");
  assert.equal(durataLavorativa({ ...base, ...p, minuti_lavorativi_preventivo: null }), null);
  assert.equal(durataLavorativa(base), null);
});

test("il ritiro prenotato non è effettuato e quello effettuato non è ricevuto", () => {
  assert.equal(azione({ attivita_operative: [ritiro] }).titolo, "Attendere il ritiro prenotato");
  assert.equal(azione({ attivita_operative: [{ ...ritiro, data_ritiro_prevista: "2026-11-06" }] }).titolo, "Verificare l’esito del ritiro");
  assert.equal(azione({ attivita_operative: [{ ...ritiro, metadati: { gls: { stato: "effettuata" } } }] }).titolo, "Attendere la ricezione");
  for (const stato of ["non_effettuata", "da_verificare", "annullata"] as const) {
    assert.equal(azione({ attivita_operative: [{ ...ritiro, metadati: { gls: { stato } } }] }).stato, "da_lavorare");
  }
});

test("un'attività in attesa non nasconde azioni, urgenze o un altro ritiro scaduto", () => {
  assert.equal(azione({ ...ordine, attivita_operative: [ritiro] }).titolo, "Preparare la fatturazione");
  assert.equal(azione({ attivita_operative: [ritiro, { ...ritiro, data_ritiro_prevista: "2026-11-06" }] }).stato, "da_lavorare");
  assert.equal(azione({ tipo_flusso: "assistenza", stato_assistenza: "aperta", priorita_assistenza: "urgente", attivita_operative: [ritiro] }).urgente, true);
  assert.equal(azione({ assistenze_rientro: [{ stato: "ritiro_prenotato", priorita: "normale" }, { stato: "verifica_tecnica", priorita: "urgente" }] }).urgente, true);
});

test("fatture, annullamenti e attività chiuse non vengono confusi con attività da svolgere", () => {
  assert.equal(azione({ stato_fatturazione: "fatturato", attivita_operative: [{ ...ritiro, stato: "da_gestire" }] }).titolo, "Organizzare il ritiro");
  assert.equal(azione({ stato_commerciale: "rifiutato", attivita_operative: [{ ...ritiro, stato: "da_gestire" }] }).titolo, "Verificare l’attività rimasta aperta");
  assert.equal(azione({ stato_fatturazione: "fatturato", attivita_operative: [{ ...ritiro, stato: "chiusa" }] }).stato, "conclusa");
  assert.equal(azione({ stato_fatturazione: "fatturato", assistenze_rientro: [{ stato: "verifica_tecnica", priorita: "normale" }] }).area, "assistenza");
  assert.equal(azione({ stato_fatturazione: "fatturato", assistenze_rientro: [{ stato: "chiusa", priorita: "urgente", chiusa_at: "2026-11-06" }] }).stato, "conclusa");
});

test("la verifica tecnica e le correzioni manuali restano evidenti", () => {
  assert.equal(azione({ verifica_tecnica_necessaria: true }).titolo, "Eseguire la verifica tecnica");
  assert.equal(azione({ stato_completezza: "incompleta_operatore", blocco_operatore: true }).titolo, "Verificare la nota dell’operatore");
  assert.equal(azione({ stato_completezza: "sconosciuto", stato_commerciale: "sconosciuto" }).titolo, "Verificare la pratica");
});

test("contatori e filtri condividono la stessa proiezione senza modificare dati", () => {
  const pratiche: PraticaOggi[] = [
    { ...base, id: "1", coda: "DA PREVENTIVARE", minuti_lavorativi_preventivo: 60 },
    { ...base, id: "2", attivita_operative: [ritiro] },
    { ...ordine, id: "3" }, { ...base, id: "4", stato_fatturazione: "fatturato" },
    { ...base, id: "5", tipo_flusso: "assistenza", stato_assistenza: "aperta" },
  ];
  const prima = structuredClone(pratiche);
  assert.deepEqual(filtraOggi(pratiche, "oggi", giorno).map(p => p.id), ["1", "3", "5"]);
  assert.deepEqual(filtraOggi(pratiche, "oggi_urgenti", giorno).map(p => p.id), ["1"]);
  assert.deepEqual(filtraOggi(pratiche, "oggi_attesa", giorno).map(p => p.id), ["2"]);
  assert.deepEqual(filtraOggi(pratiche, "oggi_concluse", giorno).map(p => p.id), ["4"]);
  assert.deepEqual(filtraOggi(pratiche, "area_amministrazione", giorno).map(p => p.id), ["3", "4"]);
  assert.deepEqual(filtraOggi(pratiche, "area_logistica", giorno).map(p => p.id), ["2"]);
  assert.deepEqual(filtraOggi(pratiche, "area_assistenza", giorno).map(p => p.id), ["5"]);
  assert.deepEqual(pratiche, prima);
});

test("controllo assente, vecchio o in errore non appare regolare", () => {
  const ora = Date.parse("2026-11-07T10:00:00Z");
  assert.equal(controlloFermo("2026-11-07T09:45:00Z", null, ora), false);
  assert.equal(controlloFermo("2026-11-07T09:44:59Z", null, ora), true);
  for (const ultima of [null, undefined, "non valida", "2026-11-08T10:00:00Z"]) assert.equal(controlloFermo(ultima, null, ora), true);
  for (const errore of ["errore", ""]) assert.equal(controlloFermo("2026-11-07T09:59:00Z", errore, ora), true);
});

test("paginazione accetta numeri reali e scarta input ambigui", () => {
  assert.equal(numeroPagina("2"), 2);
  assert.equal(numeroPagina("15"), 15);
  for (const value of [undefined, "", "0", "-1", "2abc", "1e2", "2.5", "1000000", "\\d"]) assert.equal(numeroPagina(value), 1);
});
