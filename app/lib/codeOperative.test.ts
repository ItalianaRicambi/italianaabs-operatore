import assert from "node:assert/strict";
import test from "node:test";
import { correggiCodaOperativa } from "./codeOperative.ts";
import { ordineConfermatoAperto, ordineDaCompletare } from "./fatturazione.ts";

const richiesta = {
  tipo_flusso: "commerciale",
  stato_commerciale: "raccolta_dati",
  stato_fatturazione: "non_applicabile",
  stato_completezza: "dati_mancanti",
  verifica_tecnica_necessaria: true,
  coda: "DATI MANCANTI",
  priorita: 8,
};

test("separa una richiesta tecnica incompleta dalle offerte pronte senza cambiare dati e stato", () => {
  const originale = structuredClone(richiesta);
  const risultato = correggiCodaOperativa(richiesta);
  assert.equal(risultato.coda, "PREVENTIVO - VERIFICA TECNICA");
  assert.equal(risultato.stato_completezza, "dati_mancanti");
  assert.equal(risultato.stato_commerciale, "raccolta_dati");
  assert.deepEqual(richiesta, originale);
});

test("una richiesta completa entra nei preventivi anche con una vecchia segnalazione tecnica", () => {
  const risultato = correggiCodaOperativa({ ...richiesta, stato_completezza: "completa_da_preventivare" });
  assert.equal(risultato.coda, "DA PREVENTIVARE");
});

test("una richiesta senza elementi per la verifica tecnica resta tra i dati mancanti", () => {
  assert.equal(correggiCodaOperativa({ ...richiesta, verifica_tecnica_necessaria: false }).coda, "DATI MANCANTI");
});

test("i nuovi dati e le verifiche già richieste al cliente mantengono la loro coda", () => {
  assert.equal(correggiCodaOperativa({ ...richiesta, verifica_tecnica_necessaria: false, stato_completezza: "dati_integrati_da_verificare" }).coda, "DATI INTEGRATI - DA VERIFICARE");
  assert.equal(correggiCodaOperativa({ ...richiesta, stato_commerciale: "richiesta_verifica" }).coda, "RICHIESTE VERIFICHE - ATTESA CLIENTE");
});

for (const [stato, coda] of [
  ["preventivo_inviato", "PREVENTIVO INVIATO"],
  ["rifiutato", "RIFIUTATA"],
  ["chiuso", "CHIUSA"],
]) {
  test(`${stato} prevale su una segnalazione tecnica precedente`, () => {
    assert.equal(correggiCodaOperativa({ ...richiesta, stato_commerciale: stato }).coda, coda);
  });
}

test("una pratica fatturata non torna nella preparazione di un preventivo", () => {
  assert.equal(correggiCodaOperativa({ ...richiesta, stato_commerciale: "ordine_acquisito", stato_fatturazione: "fatturato" }).coda, "FATTURATA");
});

test("l'ordine acquisito rimane visibile e i dati amministrativi decidono la fatturabilità", () => {
  const ordine = { ...richiesta, stato_commerciale: "ordine_acquisito", stato_fatturazione: "da_fatturare", stato_amministrativo: "dati_mancanti" };
  const risultato = correggiCodaOperativa(ordine);
  assert.equal(risultato.coda, "ORDINE ACQUISITO - IN ATTESA DATI CLIENTE");
  assert.equal(ordineConfermatoAperto(risultato), true);
  assert.equal(ordineDaCompletare(risultato), true);
  const pronta = correggiCodaOperativa({ ...ordine, stato_amministrativo: "pronto_fatturazione", cliente_id: "cliente-verificato" });
  assert.equal(pronta.coda, "ORDINE ACQUISITO - DA FATTURARE");
  assert.equal(ordineDaCompletare(pronta), false);
  assert.equal(correggiCodaOperativa({ ...pronta, dati_raw: { sospensione_fatturazione_operatore: { attiva: true } } }).coda, "ORDINE ACQUISITO - IN ATTESA DATI CLIENTE");
});

test("le richieste di assistenza conservano coda e priorità", () => {
  const assistenza = { ...richiesta, tipo_flusso: "assistenza", coda: "ASSISTENZA PRIORITARIA", priorita: 1 };
  assert.deepEqual(correggiCodaOperativa(assistenza), assistenza);
});
