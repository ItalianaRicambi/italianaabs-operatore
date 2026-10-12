import test from "node:test";
import assert from "node:assert/strict";
import { salvaEVerificaDatiPratica } from "./salvataggioDatiPratica.ts";

function richiesta() {
  const form = new FormData();
  form.set("pratica_id", "00000000-0000-4000-8000-000000000001");
  form.set("targa", " aa123bb ");
  form.set("tipo_guasto", "idraulico_meccanico");
  return form;
}

test("la conferma mostra i valori realmente riletti, inclusa la normalizzazione della targa", async () => {
  const dati = richiesta();
  let inviato = false;
  const esito = await salvaEVerificaDatiPratica(dati, async form => {
    assert.equal(form, dati); inviato = true;
  }, async id => {
    assert.equal(inviato, true);
    assert.equal(id, dati.get("pratica_id"));
    return { targa: "AA123BB", marca_veicolo: "Suzuki", tipo_guasto: "idraulico_meccanico" };
  });
  assert.equal(esito.ok, true);
  assert.equal(esito.dati?.targa, "AA123BB");
  assert.equal(esito.dati?.marca_veicolo, "Suzuki");
  assert.match(esito.messaggio, /salvati e confermati/);
});

test("una richiesta fallita non conferma né rilegge dati vecchi", async () => {
  let letture = 0;
  const esito = await salvaEVerificaDatiPratica(richiesta(), async () => { throw new Error("403"); }, async () => {
    letture++; return {};
  });
  assert.equal(esito.ok, false);
  assert.equal(esito.dati, undefined);
  assert.equal(letture, 0);
  assert.match(esito.messaggio, /modifiche restano/);
});

test("se il database blocca una modifica, il modulo non la dichiara salvata", async () => {
  const esito = await salvaEVerificaDatiPratica(richiesta(), async () => {}, async () => ({
    targa: "AA123BB", tipo_guasto: "elettrico_elettronico",
  }));
  assert.equal(esito.ok, false);
  assert.equal(esito.dati, undefined);
  assert.match(esito.messaggio, /non coincidono/);
});

test("una rilettura fallita distingue l’esito incerto da una richiesta non eseguita", async () => {
  const esito = await salvaEVerificaDatiPratica(richiesta(), async () => {}, async () => { throw new Error("timeout"); });
  assert.equal(esito.ok, false);
  assert.match(esito.messaggio, /Richiesta inviata/);
});
